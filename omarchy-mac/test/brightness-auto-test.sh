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

# Stubs: wluma is present, systemctl records its arguments and answers is-enabled from a flag file.
printf '#!/bin/sh\nexit 0\n' >"$work/bin/wluma"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >>"$SYSTEMCTL_LOG"
if [[ $* == "--user is-enabled wluma.service" ]]; then
  [[ -f $ENABLED_FLAG ]] && { echo enabled; exit 0; }
  echo disabled
  exit 1
fi
exit 0
STUB
# The runtime's Apple predicate: true unless the flag file says this is another machine.
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ! -f $NOT_APPLE_FLAG ]]
STUB
chmod +x "$work/bin/wluma" "$work/bin/systemctl" "$work/bin/omarchy-hw-apple-silicon"
export NOT_APPLE_FLAG="$work/not-apple"
export SYSTEMCTL_LOG="$work/systemctl.log" ENABLED_FLAG="$work/enabled"
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

# on: seeds, writes the config once, starts the service.
rm -f "$panel" "$keyboard"
run on >/dev/null
[[ -f $panel ]] || fail 'on seeds missing data'
config="$work/config/wluma/config.toml"
grep -Fq 'name = "eDP-1"' "$config" && grep -Fq 'capturer = "none"' "$config" && grep -Fq 'gamma = false' "$config" || fail 'on writes an ambient-light-only config for the panel' "$(cat "$config")"
awk '/^\[idle\]$/ { idle = 1; next } /^\[/ { idle = 0 } idle && /^enabled = false$/ { found = 1 } END { exit !found }' "$config" || fail 'on leaves idle dimming to Omarchy' "$(cat "$config")"
# wluma drives every kbd_backlight it finds, and with its own idle off it learns the lock screen's keyboard-off as a
# choice, so the keyboard would stay dark in a dark room. The config names the LED and disables it, leaving the keyboard
# to whatever pauses on lock.
awk '/^\[\[keyboard\]\]$/ { kbd = 1; next } /^\[/ { kbd = 0 } kbd && /^name = "apple::kbd_backlight"$/ { named = 1 } kbd && /^enabled = false$/ { off = 1 } END { exit !(named && off) }' "$config" || fail 'on disables wluma for the keyboard backlight' "$(cat "$config")"
grep -Fxq -- '--user enable --now wluma.service' "$SYSTEMCTL_LOG" || fail 'on enables and starts the service' "$(cat "$SYSTEMCTL_LOG")"
# wluma drives a Studio Display's own backlight too. The config names each external connector with enabled = false,
# once per name, and leaves the panel's entry alone.
awk '/^\[\[output.backlight\]\]$/ { out = 1; next } /^\[/ { out = 0 } out && /^name = "DP-1"$/ { named = 1; count++ } out && named && /^enabled = false$/ { off = 1 } END { exit !(named && off && count == 1) }' "$config" || fail 'on disables wluma for the external connector, once' "$(cat "$config")"
! awk '/^\[\[output.backlight\]\]$/ { out = 1; panel = 0; next } /^\[/ { out = 0 } out && /^name = "eDP-1"$/ { panel = 1 } out && panel && /^enabled = false$/ { bad = 1 } END { exit !bad }' "$config" || fail 'the panel stays enabled' "$(cat "$config")"
mkdir "$sys/class/drm/card0-DP-1"
rm -f "$config"
run on >/dev/null
[[ $(grep -c '^name = "DP-1"$' "$config") == 1 ]] || fail 'a connector name shared by two cards is disabled once' "$(cat "$config")"
rmdir "$sys/class/drm/card0-DP-1"
echo '# mine' >"$config"
run on >/dev/null
[[ $(cat "$config") == '# mine' ]] || fail 'on keeps an existing config'
pass 'on seeds, writes the config once and starts wluma'
# Without a keyboard backlight the config names none.
rm -rf "$work/state" "$work/config"
mv "$sys/class/leds/apple::kbd_backlight" "$work/led-away"
run on >/dev/null
! grep -q 'keyboard' "$config" || fail 'on names no keyboard when there is none' "$(cat "$config")"
mv "$work/led-away" "$sys/class/leds/apple::kbd_backlight"
pass 'the generated config names no keyboard when there is none'

# on refuses without a sensor or without wluma.
: >"$SYSTEMCTL_LOG"
mv "$sys/bus/iio/devices/iio:device0" "$work/iio-away"
if run on >/dev/null 2>"$work/err"; then fail 'on refuses without a light sensor'; fi
grep -qi 'light sensor' "$work/err" || fail 'on says why' "$(cat "$work/err")"
mv "$work/iio-away" "$sys/bus/iio/devices/iio:device0"
# A PATH with the tools the command needs and no wluma.
stage_path_without_wluma() {
  mkdir -p "$work/nowluma"
  for tool in bash cat awk mkdir mv paste; do ln -sf "$(command -v "$tool")" "$work/nowluma/$tool"; done
  ln -sf "$work/bin/systemctl" "$work/nowluma/systemctl"
  ln -sf "$work/bin/omarchy-hw-apple-silicon" "$work/nowluma/omarchy-hw-apple-silicon"
}
stage_path_without_wluma
if PATH="$work/nowluma" "$command" on >/dev/null 2>"$work/err"; then fail 'on refuses without wluma'; fi
grep -q 'wluma is not installed' "$work/err" || fail 'on names the missing package' "$(cat "$work/err")"
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'a refused on starts nothing' "$(cat "$SYSTEMCTL_LOG")"
pass 'on refuses without a sensor or without wluma'

# wluma 4 has no --version and no keyboard or output tables, so the version comes from the package database: a 4.x
# package is refused with its version named, a wluma pacman does not know (a user build) is let through.
printf '#!/bin/bash\n[[ $* == "-Q wluma" ]] || exit 1\n[[ $WLUMA_PKG_VERSION == none ]] && exit 1\necho "wluma ${WLUMA_PKG_VERSION:-5.0.4-1}"\n' >"$work/bin/pacman"
chmod +x "$work/bin/pacman"
export WLUMA_PKG_VERSION=4.9.2-1
rm -rf "$work/config" "$work/state"
: >"$SYSTEMCTL_LOG"
if run on >/dev/null 2>"$work/err"; then fail 'on refuses wluma 4'; fi
grep -Fxq 'wluma 5.0 or newer is required, found 4.9.2' "$work/err" || fail 'on names the version it found' "$(cat "$work/err")"
[[ ! -s $SYSTEMCTL_LOG && ! -e $config ]] || fail 'a refused on starts nothing and writes no config' "$(cat "$SYSTEMCTL_LOG")"
export WLUMA_PKG_VERSION=5.0-1
run on >/dev/null || fail 'on accepts wluma 5.0'
export WLUMA_PKG_VERSION=none
rm -rf "$work/config" "$work/state"
run on >/dev/null || fail 'on accepts a wluma that pacman does not know'
export WLUMA_PKG_VERSION=5.0.4-1
pass 'on refuses wluma older than 5.0 and names the version'

# off, toggle, status.
run off >/dev/null
grep -Fxq -- '--user disable --now wluma.service' "$SYSTEMCTL_LOG" || fail 'off disables and stops the service'
: >"$SYSTEMCTL_LOG"
run toggle >/dev/null
grep -Fxq -- '--user enable --now wluma.service' "$SYSTEMCTL_LOG" || fail 'toggle turns it on when off'
touch "$ENABLED_FLAG"
: >"$SYSTEMCTL_LOG"
run toggle >/dev/null
grep -Fxq -- '--user disable --now wluma.service' "$SYSTEMCTL_LOG" || fail 'toggle turns it off when on'
pass 'off and toggle drive the service'

[[ $(run status --json) == '{"enabled":true,"lux":123}' ]] || fail 'status --json reports state and lux' "$(run status --json)"
rm -f "$ENABLED_FLAG"
[[ $(run status --json) == '{"enabled":false,"lux":123}' ]] || fail 'status --json reports off'
[[ $(run status | sed -n 2p) == 'Ambient light: 123 lux' ]] || fail 'status prints the lux once' "$(run status)"
rm "$sys/bus/iio/devices/iio:device0/in_illuminance_input"
[[ $(run status | sed -n 2p) == 'Ambient light: no reading' ]] || fail 'status says when there is no reading' "$(run status)"
[[ $(run status --json) == '{"enabled":false,"lux":null}' ]] || fail 'status --json reports a missing reading as null' "$(run status --json)"
pass 'status reports state and lux, plain and JSON'

# The menu pipes status --json through grep for '"enabled":true' (omacom/omarchy), so that substring and a zero exit
# have to hold even with no sensor and no wluma.
touch "$ENABLED_FLAG"
[[ $(run status --json) == *'"enabled":true'* ]] || fail 'status --json carries "enabled":true when on' "$(run status --json)"
rm -f "$ENABLED_FLAG"
stage_path_without_wluma
out=$(PATH="$work/nowluma" "$command" status --json) || fail 'status --json exits 0 with no wluma and no reading'
[[ $out == '{"enabled":false,"lux":null}' ]] || fail 'status --json still prints JSON with no wluma and no reading' "$out"
pass 'status --json keeps the menu contract'

if run bogus >/dev/null 2>&1; then fail 'unknown commands fail'; fi
pass 'rejects unknown commands'

# Extra arguments are an error, not ignored, and nothing runs.
: >"$SYSTEMCTL_LOG"
for args in 'off x' 'on x' 'toggle x' 'seed --force x' 'status --json x'; do
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
pass 'seed refuses an unreadable max_brightness'

# No connected internal panel and no config: on refuses before it starts or writes anything, since wluma on its
# defaults would capture the screen and dim on idle.
rm -rf "$work/state" "$work/config"
: >"$SYSTEMCTL_LOG"
echo 123 >"$sys/bus/iio/devices/iio:device0/in_illuminance_input"
echo disconnected >"$sys/class/drm/card1-eDP-1/status"
if run on >/dev/null 2>"$work/err"; then fail 'on refuses without a panel and without a config'; fi
grep -qi 'panel' "$work/err" || fail 'on says why' "$(cat "$work/err")"
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'a refused on starts nothing' "$(cat "$SYSTEMCTL_LOG")"
[[ ! -e $work/state && ! -e $work/config ]] || fail 'a refused on writes nothing' "$(find "$work/state" "$work/config" 2>&1)"
# A config of the user's own is enough: on then runs with it and the keyboard curve.
mkdir -p "$work/config/wluma"
echo '# mine' >"$work/config/wluma/config.toml"
run on >/dev/null 2>&1 || fail 'on runs with the user config and no panel'
grep -Fxq -- '--user enable --now wluma.service' "$SYSTEMCTL_LOG" || fail 'on starts wluma with the user config'
[[ $(cat "$work/config/wluma/config.toml") == '# mine' ]] || fail 'on leaves the user config alone'
echo connected >"$sys/class/drm/card1-eDP-1/status"
pass 'on refuses without a panel or a config, before touching anything'

# A panel that goes away after on's check, while the curves are written: on must say why, not exit silently.
rm -rf "$work/state" "$work/config"
: >"$SYSTEMCTL_LOG"
# The stub runs the mv this machine has, wherever it lives; it is looked up before the stub exists.
real_mv=$(command -v mv)
printf '#!/bin/bash\necho disconnected >"%s"\nexec "%s" "$@"\n' "$sys/class/drm/card1-eDP-1/status" "$real_mv" >"$work/bin/mv"
chmod +x "$work/bin/mv"
if run on >/dev/null 2>"$work/err"; then fail 'on fails when the panel goes away before the config is written'; fi
grep -q 'disconnected while' "$work/err" || fail 'on says why when the panel goes away' "$(cat "$work/err")"
[[ ! -e $config ]] || fail 'on writes no config when the panel goes away' "$(cat "$config")"
[[ ! -s $SYSTEMCTL_LOG ]] || fail 'on starts nothing when the panel goes away' "$(cat "$SYSTEMCTL_LOG")"
rm "$work/bin/mv"
echo connected >"$sys/class/drm/card1-eDP-1/status"
pass 'on says why when the panel goes away mid-run'

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
for verb in status on off toggle seed; do
  if run "$verb" >/dev/null 2>"$work/err"; then fail "$verb refuses off Apple Silicon"; fi
  grep -q 'Apple Silicon' "$work/err" || fail "$verb says why" "$(cat "$work/err")"
done
[[ ! -s $SYSTEMCTL_LOG && ! -e $work/state && ! -e $work/config ]] || fail 'a refused verb touches nothing'
rm "$NOT_APPLE_FLAG"
pass 'refuses off Apple Silicon'
