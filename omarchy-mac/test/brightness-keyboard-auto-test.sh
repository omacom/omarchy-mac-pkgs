#!/bin/bash
# shellcheck disable=SC2034 # the state variables are read by the functions taken from the helper
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"
unit="$ROOT/vendor/systemd/user/omarchy-brightness-keyboard-auto.service"
[[ -x $auto ]] || fail "omarchy-brightness-keyboard-auto is executable"
grep -F 'Drive keyboard backlight from the ambient light sensor' "$auto" >/dev/null || fail "command metadata"
[[ -f $unit ]] || fail "user unit"
[[ -L $ROOT/vendor/systemd/user/graphical-session.target.wants/omarchy-brightness-keyboard-auto.service ]] || fail "unit enabled"
grep -qxF 'ConditionPathExists=!%h/.local/state/omarchy/toggles/keyboard-light-auto-off' "$unit" || fail "unit has the off toggle"
pass "the keyboard light loop ships with its user unit and an off toggle"

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/run" "$t/home"
printf '#!/bin/bash\nexit 0\n' >"$t/bin/omarchy-hw-apple-silicon"; chmod +x "$t/bin/omarchy-hw-apple-silicon"
export PATH="$t/bin:$PATH" XDG_RUNTIME_DIR="$t/run" HOME="$t/home" CALLS="$t/calls"
: >"$CALLS"

[[ $("$auto" --map-lux 0) == 100 && $("$auto" --map-lux 94) == 50 && $("$auto" --map-lux 400) == 0 ]] ||
  fail "lux line" "$("$auto" --map-lux 0) $("$auto" --map-lux 94) $("$auto" --map-lux 400)"
"$auto" --map-lux >/dev/null 2>&1 && fail "map-lux without a value should fail"
pass "lux maps to the dark/bright line"

# A Mac with a sensor and a keyboard light, and a Neo: a sensor but no keyboard light.
mkdir -p "$t/iio/iio:device0" "$t/leds/kbd_backlight" "$t/neo-leds/apple-panel-bl"
printf 'aop-sensors-als\n' >"$t/iio/iio:device0/name"; echo 0 >"$t/iio/iio:device0/in_illuminance_input"
echo 255 >"$t/leds/kbd_backlight/max_brightness"; echo 0 >"$t/leds/kbd_backlight/brightness"
echo 255 >"$t/neo-leds/apple-panel-bl/max_brightness"; echo 0 >"$t/neo-leds/apple-panel-bl/brightness"
export OMARCHY_IIO_DEVICES_DIR="$t/iio"
OMARCHY_LEDS_DIR="$t/leds" "$auto" --available || fail "--available with sensor and LED"
OMARCHY_LEDS_DIR="$t/neo-leds" "$auto" --available && fail "--available on the Neo (no keyboard light)"
OMARCHY_LEDS_DIR="$t/neo-leds" "$auto" --once || fail "--once on the Neo exits cleanly"
pass "--available answers for the sensor and the LED, and skips the Neo"

# Stand-ins: brightnessctl (it notes whether the loop holds stock's blank lock while it writes),
# stock omarchy-brightness-keyboard (off keeps the level in $XDG_RUNTIME_DIR until restore), the
# lock helper (LOCKED=1 locked, 0 unlocked, 2 cannot tell, hang never answers) and the lid helper.
cat >"$t/bin/brightnessctl" <<'SH'
#!/bin/bash
[[ $1 == -d ]] && { d=$2; shift 2; }
led="$OMARCHY_LEDS_DIR/$d"
echo "brightnessctl $*" >>"$CALLS"
if [[ $1 == set ]]; then
  flock -n "$XDG_RUNTIME_DIR/omarchy-brightness-keyboard-$d.lock" true && echo "write without the lock" >>"$CALLS"
  echo "$2" >"$led/brightness"
fi
case $1 in get) cat "$led/brightness" ;; max) cat "$led/max_brightness" ;; esac
SH
cat >"$t/bin/stock-keyboard" <<'SH'
#!/bin/bash
led="$OMARCHY_LEDS_DIR/kbd_backlight"; saved="$XDG_RUNTIME_DIR/omarchy-brightness-keyboard-kbd_backlight"
case $1 in
  off) [[ -s $saved ]] || cat "$led/brightness" >"$saved"; echo 0 >"$led/brightness" ;;
  restore) [[ -f $saved ]] && { cat "$saved" >"$led/brightness"; rm -f "$saved"; } ;;
esac
SH
cat >"$t/bin/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash
echo locked-helper >>"$CALLS"
case ${LOCKED:-0} in 1) exit 0 ;; 0) exit 1 ;; hang) sleep 10 ;; *) exit 2 ;; esac
SH
printf '#!/bin/bash\necho lid-helper >>"$CALLS"\nexit 1\n' >"$t/bin/omarchy-hw-laptop-closed"
chmod +x "$t/bin/"*
export OMARCHY_LEDS_DIR="$t/leds"

eval "$(grep -E '^(DARK_LUX|BRIGHT_LUX|DEADBAND_PERCENT|OVERRIDE_LUX_DELTA|OVERRIDE_LUX_RATIO|EFFECTIVELY_OFF_PERCENT|MANUAL_LEVEL_FILE)=' "$auto")"
for fn in lux_to_percent read_lux read_level session_locked lid_closed apply_percent left_off tick; do
  eval "$(sed -n "/^$fn()/,/^}/p" "$auto")"
done
als_path="$t/iio/iio:device0/in_illuminance_input"; kbd_path="$t/leds/kbd_backlight"; device=kbd_backlight
max=255; last_set=""; paused=0; pause_lux=0
led() { cat "$t/leds/kbd_backlight/brightness"; }
lux() { echo "$1" >"$als_path"; }

tick; (( $(led) == 255 )) || fail "a dark room lights the keys" "got $(led)"
! grep -q 'write without the lock' "$CALLS" || fail "the write holds stock's blank lock"
pass "a dark room lights the keys, written under stock's blank lock"

: >"$CALLS"; tick; tick; tick
[[ ! -s $CALLS ]] || fail "steady state starts no process" "$(tr '\n' ' ' <"$CALLS")"
pass "steady state asks no helper and runs no brightnessctl"

stock-keyboard off
LOCKED=1 tick; (( $(led) == 0 )) || fail "locked: the keys stay blank" "got $(led)"
LOCKED=2 tick; (( $(led) == 0 )) || fail "lock state unknown (exit 2) counts as locked" "got $(led)"
LOCKED=hang tick; (( $(led) == 0 )) || fail "a lock helper that hangs counts as locked" "got $(led)"
pass "locked, unknown or hung lock state: the lock's blank is kept"

tick; (( $(led) == 255 )) || fail "keys blanked by the lock light up again" "got $(led)"
stock-keyboard restore; tick; (( $(led) == 255 )) || fail "restore leaves the room's level" "got $(led)"
pass "keys blanked by the lock screen light up again in a room that wants them"

# Off by hand (stock leaves no record): a choice, kept until the room changes a lot.
lux 94; tick; (( $(led) == 127 )) || fail "half light in a dim room" "got $(led)"
echo 0 >"$t/leds/kbd_backlight/brightness"
tick; tick; (( $(led) == 0 )) || fail "keys turned off by hand stay off" "got $(led)"
lux 150; tick; (( $(led) == 43 )) || fail "a big change in the room resumes (17 % of 255)" "got $(led)"
pass "keys turned off by hand stay off until the room changes enough"

# The off toggle: the loop does nothing while the file exists.
lux 0; echo 0 >"$t/leds/kbd_backlight/brightness"
mkdir -p "$HOME/.local/state/omarchy/toggles"; touch "$HOME/.local/state/omarchy/toggles/keyboard-light-auto-off"
LOCKED=0 "$auto" --once; (( $(led) == 0 )) || fail "the off toggle leaves the keys alone" "got $(led)"
rm "$HOME/.local/state/omarchy/toggles/keyboard-light-auto-off"
LOCKED=0 "$auto" --once; (( $(led) == 255 )) || fail "without the toggle --once lights the keys" "got $(led)"
pass "keyboard-light-auto-off turns the loop off"
