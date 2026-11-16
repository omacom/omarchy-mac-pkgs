#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
command_source="$ROOT/bin/omarchy-brightness-auto"
[[ -x $command_source ]] || fail 'ships the command'

# A fixture sysfs: the ambient light sensor, the panel and keyboard backlights, a connected eDP-1 connector.
sys="$work/sys"
mkdir -p "$sys/bus/iio/devices/iio:device0" "$sys/class/backlight/apple-panel-bl" "$sys/class/backlight/228600000.dsi.0" "$sys/class/backlight/display-pipe" \
  "$sys/class/leds/apple::kbd_backlight" "$sys/class/drm/card1-eDP-1" "$sys/class/drm/card1-DP-1" "$work/bin" "$work/state" "$work/config"
echo aop-sensors-als >"$sys/bus/iio/devices/iio:device0/name"
echo 123 >"$sys/bus/iio/devices/iio:device0/in_illuminance_input"
echo 1000 >"$sys/class/backlight/apple-panel-bl/max_brightness"
echo 255 >"$sys/class/leds/apple::kbd_backlight/max_brightness"
# The Touch Bar's backlights sort before the panel's and must never be taken for it (displays.conf skips them).
echo 100 >"$sys/class/backlight/228600000.dsi.0/max_brightness"
echo 100 >"$sys/class/backlight/display-pipe/max_brightness"
echo connected >"$sys/class/drm/card1-eDP-1/status"
echo disconnected >"$sys/class/drm/card1-DP-1/status"

# Stubs: wluma is present; systemctl records its arguments and keeps two facts, whether the unit is masked (the
# package's vendor link otherwise starts it) and whether it is stopped. Like the real one it answers "disabled" to
# is-enabled for that link, so status must read is-active. sleep only records, so ready's wait costs no time.
printf '#!/bin/sh\nexit 0\n' >"$work/bin/wluma"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >>"$SYSTEMCTL_LOG"
case $* in
  "--user mask --now wluma.service") : >"$MASKED_FLAG" ;;
  "--user unmask wluma.service") rm -f "$MASKED_FLAG" ;;
  "--user is-active --quiet wluma.service")
    [[ -f $MASKED_FLAG || -f $STOPPED_FLAG || -f $STARTING_FLAG ]] && exit 3
    exit 0 ;;
  "--user is-active wluma.service")
    if [[ -f $MASKED_FLAG || -f $STOPPED_FLAG ]]; then echo inactive; exit 3; fi
    if [[ -f $STARTING_FLAG ]]; then echo activating; exit 3; fi
    echo active; exit 0 ;;
  "--user is-enabled wluma.service")
    echo disabled; exit 1 ;;
esac
exit 0
STUB
printf '#!/bin/bash\necho "$*" >>"$SLEEP_LOG"\nif [[ -n ${SLEEP_FILL:-} && $(wc -l <"$SLEEP_LOG") -ge 3 ]]; then rmdir "$SLEEP_FILL"; echo 5 >"$SLEEP_FILL"; fi\nif [[ -n ${SLEEP_MV:-} && $(wc -l <"$SLEEP_LOG") -ge 3 && -e ${SLEEP_MV%% *} ]]; then mv $SLEEP_MV; fi\n' >"$work/bin/sleep"
# The runtime's Apple predicate: true unless the flag file says this is another machine.
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ! -f $NOT_APPLE_FLAG ]]
STUB
chmod +x "$work/bin/wluma" "$work/bin/systemctl" "$work/bin/sleep" "$work/bin/omarchy-hw-apple-silicon"
export NOT_APPLE_FLAG="$work/not-apple" SLEEP_LOG="$work/sleep.log"
export SYSTEMCTL_LOG="$work/systemctl.log" MASKED_FLAG="$work/masked" STOPPED_FLAG="$work/stopped" STARTING_FLAG="$work/starting"
export XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config"
: >"$SYSTEMCTL_LOG"

command="$work/bin/omarchy-brightness-auto"
sed -e "s|^sys_root=.*|sys_root=$sys|" -e "s|^displays_conf=.*|displays_conf=$ROOT/share/omarchy-platform/displays.conf|" "$command_source" >"$command"
chmod +x "$command"
run() { PATH="$work/bin:$PATH" "$command" "$@"; }

panel="$work/state/wluma/eDP-1.yaml"
keyboard="$work/state/wluma/apple::kbd_backlight.yaml"

# Seed curves.
run seed >/dev/null
[[ -f $panel && -f $keyboard ]] || fail 'seed writes one file per panel and keyboard, named as wluma names them'
grep -Fxq 'output_name: eDP-1' "$panel" || fail 'panel file names its output'
grep -Fxq 'output_name: apple::kbd_backlight' "$keyboard" || fail 'keyboard file names its output'
values() { awk '/^ +value: / { print $2 }' "$1" | paste -sd' '; }
lux() { awk '/^ +- als: / { print $3 }' "$1" | paste -sd' '; }
panel_values=$(values "$panel")
keyboard_values=$(values "$keyboard")
sorted_up=$(tr ' ' '\n' <<<"$panel_values" | sort -n | paste -sd' ')
sorted_down=$(tr ' ' '\n' <<<"$keyboard_values" | sort -rn | paste -sd' ')
[[ $panel_values == "$sorted_up" ]] || fail 'the panel gets brighter with the light' "$panel_values"
[[ $keyboard_values == "$sorted_down" ]] || fail 'the keyboard gets dimmer with the light' "$keyboard_values"
[[ ${panel_values##* } == 1000 ]] || fail 'the panel reaches its maximum in daylight' "$panel_values"
(( ${panel_values%% *} >= 1 && ${panel_values%% *} <= 100 )) || fail 'the panel never goes dark' "$panel_values"
[[ ${keyboard_values##* } == 0 ]] && (( ${keyboard_values%% *} >= 64 && ${keyboard_values%% *} <= 255 )) || fail 'the keyboard is lit in the dark and off in daylight' "$keyboard_values"
[[ $(lux "$panel" | cut -d' ' -f1) == 0 ]] || fail 'the curve starts at zero lux'
pass 'seed writes monotonic curves scaled to the device ranges'

# Seed keeps what wluma learned.
echo learned >"$panel"
run seed >/dev/null
[[ $(cat "$panel") == learned ]] || fail 'seed leaves an existing file alone'
run seed --force >/dev/null
grep -Fxq 'output_name: eDP-1' "$panel" || fail 'seed --force replaces it'
pass 'seed never overwrites learned data without --force'

# A smaller panel range scales the curve.
echo 255 >"$sys/class/backlight/apple-panel-bl/max_brightness"
run seed --force >/dev/null
[[ $(values "$panel" | tr ' ' '\n' | tail -1) == 255 ]] || fail 'the curve follows max_brightness'
echo 1000 >"$sys/class/backlight/apple-panel-bl/max_brightness"
run seed --force >/dev/null
pass 'seed scales to max_brightness'

# prepare, run by the unit before every start: seeds missing data, writes the config once, keeps a user's.
rm -f "$panel" "$keyboard"
run prepare >/dev/null
[[ -f $panel ]] || fail 'prepare seeds missing data'
config="$work/config/wluma/config.toml"
grep -Fq 'name = "eDP-1"' "$config" && grep -Fq 'capturer = "none"' "$config" && grep -Fq 'gamma = false' "$config" || fail 'prepare writes an ambient-light-only config for the panel' "$(cat "$config")"
awk '/^\[idle\]$/ { idle = 1; next } /^\[/ { idle = 0 } idle && /^enabled = false$/ { found = 1 } END { exit !found }' "$config" || fail 'prepare leaves idle dimming to Omarchy' "$(cat "$config")"
# wluma drives every kbd_backlight it finds, and with its own idle off it learns the lock screen's keyboard-off as a
# choice, so the keyboard would stay dark in a dark room. The config names the LED and disables it, leaving the keyboard
# to whatever pauses on lock.
awk '/^\[\[keyboard\]\]$/ { kbd = 1; next } /^\[/ { kbd = 0 } kbd && /^name = "apple::kbd_backlight"$/ { named = 1 } kbd && /^enabled = false$/ { off = 1 } END { exit !(named && off) }' "$config" || fail 'prepare disables wluma for the keyboard backlight' "$(cat "$config")"
echo '# mine' >"$config"
echo learned >"$panel"
run prepare >/dev/null
[[ $(cat "$config") == '# mine' && $(cat "$panel") == learned ]] || fail 'prepare keeps an existing config and learned curve'
: >"$SYSTEMCTL_LOG"
run prepare >/dev/null
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'prepare starts nothing' "$(cat "$SYSTEMCTL_LOG")"
pass 'prepare seeds and configures once and never overwrites'

# Without a keyboard backlight the config names none.
rm -rf "$work/state" "$work/config"
mv "$sys/class/leds/apple::kbd_backlight" "$work/led-away"
run prepare >/dev/null
! grep -q 'keyboard' "$config" || fail 'prepare names no keyboard when there is none' "$(cat "$config")"
mv "$work/led-away" "$sys/class/leds/apple::kbd_backlight"
pass 'the generated config names no keyboard without a keyboard backlight'

# A device whose maximum cannot be read must not make prepare fail: the unit still starts, on what wluma has.
rm -f "$panel"
max_file="$sys/class/backlight/apple-panel-bl/max_brightness"
max_was=$(<"$max_file")
: >"$max_file"
run prepare >/dev/null 2>"$work/err" || fail 'prepare succeeds when a maximum cannot be read' "$(cat "$work/err")"
grep -q 'max_brightness' "$work/err" || fail 'prepare names the bad maximum' "$(cat "$work/err")"
[[ ! -e $panel ]] || fail 'prepare writes no curve for it'
echo "$max_was" >"$max_file"
pass 'prepare survives an unreadable max_brightness'

# ready, asked by the unit before every start: wluma, a sensor, and a number from it.
: >"$SLEEP_LOG"
run ready || fail 'ready is true with wluma and a reading'
[[ ! -s $SLEEP_LOG ]] || fail 'ready does not wait when the sensor already reports'
mv "$sys/bus/iio/devices/iio:device0" "$work/iio-away"
if run ready; then fail 'ready is false without a sensor'; fi
[[ ! -s $SLEEP_LOG ]] || fail 'ready does not wait for a sensor that is not there'
# With an always-on processor node the sensor's driver may still load: wait for it, then give up.
mkdir -p "$sys/bus/platform/devices/290c00000.aop"
if run ready; then fail 'ready is false when the sensor never appears'; fi
[[ $(wc -l <"$SLEEP_LOG") == 59 ]] || fail 'ready waits 59 s for a sensor that may still load' "$(wc -l <"$SLEEP_LOG")"
rmdir "$sys/bus/platform/devices/290c00000.aop"
: >"$SLEEP_LOG"
mv "$work/iio-away" "$sys/bus/iio/devices/iio:device0"
reading="$sys/bus/iio/devices/iio:device0/in_illuminance_input"
# A read that fails, as the sensor's does until it reports (ENODATA), stood in for by a directory.
rm "$reading"
mkdir "$reading"
if run ready; then fail 'ready is false while the sensor gives no number'; fi
[[ $(wc -l <"$SLEEP_LOG") == 59 ]] || fail 'ready waits 59 s for a first reading, then gives up' "$(wc -l <"$SLEEP_LOG")"
rmdir "$reading"
echo 'not a number' >"$reading"
if run ready; then fail 'ready is false when the reading is not a number'; fi
: >"$SLEEP_LOG"
rm "$reading"
mkdir "$reading"
SLEEP_FILL="$reading" run ready || fail 'ready is true once the sensor reports within the wait'
echo 123 >"$reading"
# The case the wait exists for: the sensor directory is absent, the always-on processor node is there, and the
# directory appears while ready waits.
mv "$sys/bus/iio/devices/iio:device0" "$work/iio-away"
mkdir -p "$sys/bus/platform/devices/290c00000.aop"
: >"$SLEEP_LOG"
SLEEP_MV="$work/iio-away $sys/bus/iio/devices/iio:device0" run ready || fail 'ready is true once the sensor directory appears within the wait'
[[ $(wc -l <"$SLEEP_LOG") -ge 3 ]] || fail 'ready waited for the sensor directory' "$(wc -l <"$SLEEP_LOG")"
rmdir "$sys/bus/platform/devices/290c00000.aop"
pass 'ready needs wluma, a sensor and a number, and waits for the first reading'

# on unmasks and starts the service.
: >"$SYSTEMCTL_LOG"
run on >/dev/null
[[ $(cat "$SYSTEMCTL_LOG") == $'--user unmask wluma.service\n--user start wluma.service' ]] || fail 'on unmasks and starts the service' "$(cat "$SYSTEMCTL_LOG")"
pass 'on unmasks and starts wluma'

# on tells the user why it is slow when the sensor has not reported yet.
: >"$reading"
run on >/dev/null 2>"$work/err" || fail 'on still starts with no reading yet'
grep -q '60 s' "$work/err" || fail 'on says it waits for the sensor' "$(cat "$work/err")"
echo 123 >"$reading"
run on >/dev/null 2>"$work/err"
[[ ! -s $work/err ]] || fail 'on is silent when the sensor already reports' "$(cat "$work/err")"
pass 'on says when it waits for the sensor'

# on refuses without a sensor or without wluma.
: >"$SYSTEMCTL_LOG"
mv "$sys/bus/iio/devices/iio:device0" "$work/iio-away"
if run on >/dev/null 2>"$work/err"; then fail 'on refuses without a light sensor'; fi
grep -qi 'light sensor' "$work/err" || fail 'on says why' "$(cat "$work/err")"
mv "$work/iio-away" "$sys/bus/iio/devices/iio:device0"
# A PATH with the tools the command needs and no wluma.
mkdir -p "$work/nowluma"
for tool in bash cat awk mkdir mv paste; do ln -sf "$(command -v "$tool")" "$work/nowluma/$tool"; done
ln -sf "$work/bin/systemctl" "$work/nowluma/systemctl"
ln -sf "$work/bin/omarchy-hw-apple-silicon" "$work/nowluma/omarchy-hw-apple-silicon"
if PATH="$work/nowluma" "$command" on >/dev/null 2>"$work/err"; then fail 'on refuses without wluma'; fi
grep -q 'wluma is not installed' "$work/err" || fail 'on names the missing package' "$(cat "$work/err")"
if PATH="$work/nowluma" "$command" ready; then fail 'ready is false without wluma'; fi
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'a refused on starts nothing' "$(cat "$SYSTEMCTL_LOG")"
pass 'on refuses without a sensor or without wluma'

# off, on and toggle from both states; the vendor link leaves the unit on until it is masked.
enabled_json() { run status --json | sed -E 's/.*"enabled":([a-z]+).*/\1/'; }
rm -f "$MASKED_FLAG"
[[ $(enabled_json) == true ]] || fail 'status reports on for the vendor link'
: >"$SYSTEMCTL_LOG"
run off >/dev/null
[[ $(cat "$SYSTEMCTL_LOG") == '--user mask --now wluma.service' ]] || fail 'off masks and stops the service' "$(cat "$SYSTEMCTL_LOG")"
[[ $(enabled_json) == false && $(run status | sed -n 1p) == 'Automatic brightness: off' ]] || fail 'status reports off when masked'
run off >/dev/null
[[ $(enabled_json) == false ]] || fail 'off twice stays off'
: >"$SYSTEMCTL_LOG"
run toggle >/dev/null
grep -Fxq -- '--user start wluma.service' "$SYSTEMCTL_LOG" || fail 'toggle turns it on when off'
[[ $(enabled_json) == true ]] || fail 'toggle from off leaves it on'
run on >/dev/null
[[ $(enabled_json) == true ]] || fail 'on when on stays on'
: >"$SYSTEMCTL_LOG"
run toggle >/dev/null
grep -Fxq -- '--user mask --now wluma.service' "$SYSTEMCTL_LOG" || fail 'toggle turns it off when on'
[[ $(enabled_json) == false ]] || fail 'toggle from on leaves it off'
run on >/dev/null
[[ $(enabled_json) == true ]] || fail 'on turns it on from off'
: >"$STOPPED_FLAG"
[[ $(enabled_json) == false && $(run status | sed -n 1p) == 'Automatic brightness: off' ]] || fail 'status reports off when the unit is not running'
: >"$SYSTEMCTL_LOG"
run toggle >/dev/null
grep -Fxq -- '--user start wluma.service' "$SYSTEMCTL_LOG" || fail 'toggle starts a unit that is not running'
rm -f "$STOPPED_FLAG"
: >"$STARTING_FLAG"
[[ $(run status | sed -n 1p) == 'Automatic brightness: starting' && $(enabled_json) == false ]] || fail 'status says starting while the unit activates' "$(run status)"
rm -f "$STARTING_FLAG"
pass 'off, on and toggle work from both states'

[[ $(run status --json) == '{"enabled":true,"lux":123}' ]] || fail 'status --json reports state and lux' "$(run status --json)"
[[ $(run status | sed -n 2p) == 'Ambient light: 123 lux' ]] || fail 'status prints the lux once' "$(run status)"
run off >/dev/null
[[ $(run status --json) == '{"enabled":false,"lux":123}' ]] || fail 'status --json reports off'
rm "$sys/bus/iio/devices/iio:device0/in_illuminance_input"
[[ $(run status | sed -n 2p) == 'Ambient light: no reading' ]] || fail 'status says when there is no reading' "$(run status)"
[[ $(run status --json) == '{"enabled":false,"lux":null}' ]] || fail 'status --json reports a missing reading as null' "$(run status --json)"
echo 123 >"$reading"
pass 'status reports state and lux, plain and JSON'

# The menu pipes status --json through grep for '"enabled":true' (omacom/omarchy), so that substring and a zero exit
# have to hold even with no sensor and no wluma.
rm -f "$MASKED_FLAG" "$STOPPED_FLAG"
[[ $(run status --json) == *'"enabled":true'* ]] || fail 'status --json carries "enabled":true when on' "$(run status --json)"
touch "$MASKED_FLAG"
rm "$reading"
mkdir -p "$work/nowluma"
for tool in bash cat awk mkdir mv paste; do ln -sf "$(command -v "$tool")" "$work/nowluma/$tool"; done
ln -sf "$work/bin/systemctl" "$work/nowluma/systemctl"
ln -sf "$work/bin/omarchy-hw-apple-silicon" "$work/nowluma/omarchy-hw-apple-silicon"
out=$(PATH="$work/nowluma" "$command" status --json) || fail 'status --json exits 0 with no wluma and no reading'
[[ $out == '{"enabled":false,"lux":null}' ]] || fail 'status --json still prints JSON with no wluma and no reading' "$out"
echo 123 >"$reading"
pass 'status --json keeps the menu contract'

if run bogus >/dev/null 2>&1; then fail 'unknown commands fail'; fi
pass 'rejects unknown commands'

# Extra arguments are an error, not ignored, and nothing runs.
: >"$SYSTEMCTL_LOG"
for args in 'off x' 'on x' 'toggle x' 'ready x' 'prepare x' 'seed --force x' 'status --json x'; do
  # shellcheck disable=SC2086
  if run $args >/dev/null 2>&1; then fail "'$args' is refused"; fi
done
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'a refused call starts nothing' "$(cat "$SYSTEMCTL_LOG")"
pass 'rejects extra arguments'

# A device whose maximum cannot be read must not get an all-zero curve.
rm -rf "$work/state"
: >"$sys/class/backlight/apple-panel-bl/max_brightness"
if run seed >/dev/null 2>"$work/err"; then fail 'seed refuses an unreadable maximum'; fi
grep -q 'max_brightness' "$work/err" || fail 'seed names the bad maximum' "$(cat "$work/err")"
[[ ! -e $work/state/wluma/eDP-1.yaml ]] || fail 'seed writes no curve for it'
echo 1000 >"$sys/class/backlight/apple-panel-bl/max_brightness"
kbd=$(find "$sys/class/leds" -maxdepth 1 -name '*kbd_backlight*' | head -1)
: >"$kbd/max_brightness"
rm -rf "$work/state"
if run seed >/dev/null 2>"$work/err"; then fail 'seed fails when the keyboard maximum cannot be read'; fi
grep -q 'max_brightness' "$work/err" || fail 'seed names the bad keyboard maximum' "$(cat "$work/err")"
echo 255 >"$kbd/max_brightness"
mv "$sys/class/backlight/apple-panel-bl" "$work/panel-gone"
mv "$kbd" "$work/kbd-gone"
rm -rf "$work/state"
if run seed >/dev/null 2>"$work/err"; then fail 'seed fails with nothing to seed'; fi
grep -q 'No internal display backlight or keyboard backlight' "$work/err" || fail 'seed says there is nothing to seed' "$(cat "$work/err")"
mv "$work/panel-gone" "$sys/class/backlight/apple-panel-bl"
mv "$work/kbd-gone" "$kbd"
pass 'seed refuses an unreadable max_brightness'

# No connected internal panel and no config: on refuses before it starts or writes anything, since wluma on its
# defaults would capture the screen and dim on idle. The unit's start condition stays false for the same reason,
# and prepare fails and says why, so a start that got past the condition still does not run wluma on its defaults.
rm -rf "$work/state" "$work/config"
: >"$SYSTEMCTL_LOG"
echo 123 >"$sys/bus/iio/devices/iio:device0/in_illuminance_input"
echo disconnected >"$sys/class/drm/card1-eDP-1/status"
if run on >/dev/null 2>"$work/err"; then fail 'on refuses without a panel and without a config'; fi
grep -qi 'panel' "$work/err" || fail 'on says why' "$(cat "$work/err")"
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'a refused on starts nothing' "$(cat "$SYSTEMCTL_LOG")"
[[ ! -e $work/state && ! -e $work/config ]] || fail 'a refused on writes nothing' "$(find "$work/state" "$work/config" 2>&1)"
if run ready >/dev/null 2>&1; then fail 'ready stays false without a panel and without a config'; fi
if run prepare >/dev/null 2>"$work/err"; then fail 'prepare fails without a panel and without a config'; fi
grep -qi 'panel' "$work/err" || fail 'prepare says why it left no config' "$(cat "$work/err")"
[[ ! -e $work/config/wluma/config.toml ]] || fail 'a failed prepare writes no config'
# A config of the user's own is enough: on then runs with it and the keyboard curve.
mkdir -p "$work/config/wluma"
echo '# mine' >"$work/config/wluma/config.toml"
run ready >/dev/null 2>&1 || fail 'ready is true with the user config and no panel'
: >"$SYSTEMCTL_LOG"
run on >/dev/null 2>&1 || fail 'on runs with the user config and no panel'
grep -Fxq -- '--user start wluma.service' "$SYSTEMCTL_LOG" || fail 'on starts wluma with the user config' "$(cat "$SYSTEMCTL_LOG")"
[[ $(cat "$work/config/wluma/config.toml") == '# mine' ]] || fail 'on leaves the user config alone'
echo connected >"$sys/class/drm/card1-eDP-1/status"
pass 'a missing panel and a missing config keep wluma stopped, before touching anything'

# The panel is there when ready runs and gone when prepare runs: prepare must fail, not leave a start on defaults.
rm -rf "$work/state" "$work/config"
run ready >/dev/null 2>&1 || fail 'ready is true while the panel is connected'
echo disconnected >"$sys/class/drm/card1-eDP-1/status"
if run prepare >/dev/null 2>"$work/err"; then fail 'prepare fails when the panel goes away after ready'; fi
grep -qi 'panel' "$work/err" || fail 'prepare says why when the panel goes away after ready' "$(cat "$work/err")"
[[ ! -e $work/config/wluma/config.toml ]] || fail 'prepare writes no config for a panel that went away'
echo connected >"$sys/class/drm/card1-eDP-1/status"
pass 'a panel that goes away between ready and prepare stops the start'

# A write that fails must fail prepare and seed, leave no partial file, and never replace a good curve. prepare and
# write_curve run on the left of || in the callers, where set -e is off, so every step reports its own failure.
mv "$sys/class/leds/apple::kbd_backlight" "$work/led-away"
rm -rf "$work/state" "$work/config"
: >"$work/config"
if run prepare >/dev/null 2>&1; then fail 'prepare fails when the config directory cannot be made'; fi
rm -f "$work/config"
mkdir -p "$work/config/wluma/config.toml.tmp"
if run prepare >/dev/null 2>&1; then fail 'prepare fails when the config cannot be written'; fi
[[ ! -e $work/config/wluma/config.toml ]] || fail 'a failed config write leaves no config' "$(cat "$work/config/wluma/config.toml")"
mv "$work/led-away" "$sys/class/leds/apple::kbd_backlight"
rm -rf "$work/state" "$work/config"
run seed >/dev/null
good=$(cat "$panel")
printf '#!/bin/bash\ncase "$*" in *maximum=*) echo "  - als: 1"; exit 2 ;; esac\nexec /usr/bin/awk "$@"\n' >"$work/bin/awk"
chmod +x "$work/bin/awk"
if run seed --force >/dev/null 2>&1; then fail 'seed fails when the curve cannot be built'; fi
[[ $(cat "$panel") == "$good" ]] || fail 'a failed rewrite leaves the good curve in place' "$(cat "$panel")"
[[ ! -e $panel.tmp ]] || fail 'a failed rewrite leaves no temp file'
rm -f "$work/bin/awk" "$panel"
ln -s /dev/full "$panel.tmp"
if run seed >/dev/null 2>&1; then fail 'seed fails when the curve cannot be written'; fi
[[ ! -e $panel && ! -L $panel.tmp ]] || fail 'a failed curve write leaves no curve and no temp file'
pass 'a failed write fails prepare and seed and leaves no partial file'

# Touch Bar backlights are skipped, and the panel is preferred over any other.
rm -rf "$work/state"
run seed >/dev/null
(( $(tail -1 < <(values "$panel" | tr ' ' '\n')) == 1000 )) || fail 'the panel curve is not scaled to a Touch Bar backlight' "$(values "$panel")"
mv "$sys/class/backlight/apple-panel-bl" "$work/panel-away"
rm -rf "$work/state"
run seed >/dev/null
[[ ! -e $panel ]] || fail 'with only Touch Bar backlights no panel curve is written'
mkdir -p "$sys/class/backlight/intel_backlight"
echo 500 >"$sys/class/backlight/intel_backlight/max_brightness"
run seed >/dev/null
(( $(tail -1 < <(values "$panel" | tr ' ' '\n')) == 500 )) || fail 'another backlight serves when the panel one is missing' "$(values "$panel")"
mkdir "$sys/class/backlight/a-other"
echo 77 >"$sys/class/backlight/a-other/max_brightness"
mv "$work/panel-away" "$sys/class/backlight/apple-panel-bl"
rm -rf "$work/state"
run seed >/dev/null
(( $(tail -1 < <(values "$panel" | tr ' ' '\n')) == 1000 )) || fail 'the preferred backlight wins' "$(values "$panel")"
rm -rf "$sys/class/backlight/intel_backlight" "$sys/class/backlight/a-other"
pass 'seed skips Touch Bar backlights and prefers the panel'

# Off Apple Silicon every verb refuses and touches nothing.
touch "$NOT_APPLE_FLAG"
rm -rf "$work/state" "$work/config"
: >"$SYSTEMCTL_LOG"
for verb in status on off toggle seed ready prepare; do
  if run "$verb" >/dev/null 2>"$work/err"; then fail "$verb refuses off Apple Silicon"; fi
  grep -q 'Apple Silicon' "$work/err" || fail "$verb says why" "$(cat "$work/err")"
done
[[ ! -s $SYSTEMCTL_LOG && ! -e $work/state && ! -e $work/config ]] || fail 'a refused verb touches nothing'
rm "$NOT_APPLE_FLAG"
pass 'refuses off Apple Silicon'

# The package turns the unit on for everyone, and asks the command before each start.
"$ROOT"/install "$work/root" >/dev/null
user_units="$work/root/usr/lib/systemd/user"
[[ $(readlink "$user_units/graphical-session.target.wants/wluma.service") == ../wluma.service ]] || fail 'the package links wluma.service into graphical-session.target.wants'
dropin="$user_units/wluma.service.d/omarchy-mac.conf"
grep -Fxq 'ExecCondition=/usr/bin/omarchy-brightness-auto ready' "$dropin" || fail 'the drop-in starts wluma only with a sensor'
grep -Fxq 'ExecStartPre=/usr/bin/omarchy-brightness-auto prepare' "$dropin" || fail 'the drop-in runs prepare before a start, and a failed prepare stops the start'
[[ -x $work/root/usr/bin/omarchy-brightness-auto ]] || fail 'the drop-in names an installed command'
pass 'the package enables wluma by default'
