#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-display-white-point-auto"
unit="$ROOT/vendor/systemd/user/omarchy-display-white-point-auto.service"
[[ -x $auto ]] || fail "omarchy-display-white-point-auto is executable"
grep -F 'Follow the colour of the room light with the display white point' "$auto" >/dev/null || fail "command metadata"
[[ -f $unit ]] || fail "user unit"
[[ -L $ROOT/vendor/systemd/user/graphical-session.target.wants/omarchy-display-white-point-auto.service ]] || fail "unit linked to the session"
grep -qxF 'ConditionPathExists=%h/.local/state/omarchy/toggles/white-point-auto-on' "$unit" || fail "unit waits for the on toggle"
pass "the white point loop ships with its user unit, off until its toggle is created"

t=$(mktemp -d)
loop=""
cleanup() {
  [[ -z $loop ]] || kill "$loop" 2>/dev/null || true
  rm -rf "$t"
}
trap cleanup EXIT
mkdir -p "$t/bin" "$t/home" "$t/run"
printf '#!/bin/bash\nexit 0\n' >"$t/bin/omarchy-hw-apple-silicon"
# hyprsunset as hyprctl sees it: its temperature in $SCREEN, no answer while $SCREEN is missing.
cat >"$t/bin/hyprctl" <<'SH'
#!/bin/bash
[[ $1 == hyprsunset && -f $SCREEN ]] || exit 3
case $2 in
  temperature)
    if [[ -n ${3:-} ]]; then
      echo "$3" >"$SCREEN"; echo "temperature $3" >>"$CALLS"; echo ok
    else
      cat "$SCREEN"
    fi
    ;;
  identity) echo identity >>"$CALLS"; echo ok ;;
esac
SH
printf '#!/bin/bash\nexit 1\n' >"$t/bin/pgrep"
# shellcheck disable=SC2016 # the stand-in expands $CALLS when it runs
printf '#!/bin/bash\necho "start $*" >>"$CALLS"\n' >"$t/bin/uwsm-app"
# The fade's short pauses are skipped; the loop's own poll still waits.
printf '#!/bin/bash\n[[ $1 == 0.* ]] && exit 0\nexec /usr/bin/sleep "$@"\n' >"$t/bin/sleep"
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" HOME="$t/home" XDG_RUNTIME_DIR="$t/run" SCREEN="$t/screen" CALLS="$t/calls"
unset XDG_STATE_HOME
state="$t/home/.local/state/omarchy/white-point-auto"
toggle="$t/home/.local/state/omarchy/toggles/white-point-auto-on"

# A quarter of the way from the panel's 6500 K to the room, in mired, kept between 4800 K and 6500 K.
[[ $("$auto" --map-cct 2700) == 4800 && $("$auto" --map-cct 4000) == 5600 && $("$auto" --map-cct 5000) == 6050 ]] ||
  fail "warm rooms" "$("$auto" --map-cct 2700) $("$auto" --map-cct 4000) $("$auto" --map-cct 5000)"
[[ $("$auto" --map-cct 6500) == 6500 && $("$auto" --map-cct 9000) == 6500 && $("$auto" --map-cct 1000) == 4800 ]] ||
  fail "daylight and the warm limit" "$("$auto" --map-cct 6500) $("$auto" --map-cct 9000) $("$auto" --map-cct 1000)"
"$auto" --map-cct >/dev/null 2>&1 && fail "map-cct without a value should fail"
"$auto" --map-cct warm >/dev/null 2>&1 && fail "map-cct with a word should fail"
pass "a room's colour temperature maps to a white point between 4800 K and native 6500 K"

# The M1 Air's sensor, an older kernel's sensor without colour channels, and the lid angle sensor alone.
mkdir -p "$t/iio/iio:device0" "$t/old/iio:device0" "$t/lid/iio:device0"
printf 'aop-sensors-als\n' >"$t/iio/iio:device0/name"
printf 'aop-sensors-als\n' >"$t/old/iio:device0/name"
printf 'aop-sensors-las\n' >"$t/lid/iio:device0/name"
echo 0.041814 >"$t/old/iio:device0/in_illuminance_input"
echo 1 >"$t/lid/iio:device0/in_colortemp_input"; echo 1 >"$t/lid/iio:device0/in_illuminance_input"
sensor="$t/iio/iio:device0"
room() { echo "$1" >"$sensor/in_illuminance_input"; echo "$2" >"$sensor/in_colortemp_input"; }
room 92.265228 6200.377929
OMARCHY_IIO_DEVICES_DIR="$t/iio" "$auto" --available || fail "--available with a colour sensor"
OMARCHY_IIO_DEVICES_DIR="$t/old" "$auto" --available && fail "--available with a sensor that has no colour temperature"
OMARCHY_IIO_DEVICES_DIR="$t/lid" "$auto" --available && fail "--available with only the lid angle sensor"
printf '#!/bin/bash\nexit 1\n' >"$t/bin/omarchy-hw-apple-silicon"
OMARCHY_IIO_DEVICES_DIR="$t/iio" "$auto" --available && fail "--available off Apple Silicon"
printf '#!/bin/bash\nexit 0\n' >"$t/bin/omarchy-hw-apple-silicon"
pass "--available needs an ambient light sensor with a colour temperature channel"
export OMARCHY_IIO_DEVICES_DIR="$t/iio"

screen() { cat "$SCREEN"; }
reset() { echo "$1" >"$SCREEN"; : >"$CALLS"; }

reset 6000; room 300 2700
"$auto" --once
[[ ! -s $CALLS && $(screen) == 6000 ]] || fail "without the on toggle nothing is written" "$(tr '\n' ' ' <"$CALLS")"
mkdir -p "${toggle%/*}"; : >"$toggle"
pass "the loop does nothing until its toggle is created"

"$auto" --once
[[ $(screen) == 4800 && $(<"$state") == 4800 ]] || fail "a warm room warms the screen" "$(screen) $(<"$state")"
grep -q identity "$CALLS" && fail "a warm white point is not the identity matrix"
reset 4800; room 300 4000; "$auto" --once
[[ $(screen) == 5600 && $(<"$state") == 5600 ]] || fail "a less warm room follows" "$(screen)"
pass "a warm room warms the screen from hyprsunset's default, and the record says what was written"

reset 5600; room 300 4100; "$auto" --once
[[ ! -s $CALLS ]] || fail "a change under 100 K is not written" "$(tr '\n' ' ' <"$CALLS")"
reset 5600; room 2 2700; "$auto" --once
[[ ! -s $CALLS ]] || fail "a dim room's colour is not used" "$(tr '\n' ' ' <"$CALLS")"
reset 5600; echo 0.041814 >"$sensor/in_illuminance_input"; : >"$sensor/in_colortemp_input"; "$auto" --once
[[ ! -s $CALLS ]] || fail "a dark room without a colour reading holds the white point" "$(tr '\n' ' ' <"$CALLS")"
pass "small changes, dim rooms and a dark room with no colour reading leave the white point"

reset 5600; room 1000 7000; "$auto" --once
[[ $(screen) == 6500 ]] && grep -qx identity "$CALLS" || fail "daylight returns to native white" "$(screen) $(tr '\n' ' ' <"$CALLS")"
[[ ! -e $state ]] || fail "at native white the loop holds nothing" "$(<"$state")"
reset 6500; "$auto" --once
[[ ! -s $CALLS ]] || fail "native white already shown is left" "$(tr '\n' ' ' <"$CALLS")"
pass "daylight puts the identity matrix back and holds nothing"

# Night light is any warm temperature this loop did not write, including one warmer than its own limit or not.
echo 4800 >"$state"
for night in 4000 5000 5900; do
  reset "$night"; room 300 2700; "$auto" --once
  [[ ! -s $CALLS && $(screen) == "$night" ]] || fail "night light at $night K is left alone" "$(tr '\n' ' ' <"$CALLS")"
done
rm -f "$state"
reset 4000; room 1000 7000; "$auto" --once
[[ ! -s $CALLS ]] || fail "night light is left even in daylight" "$(tr '\n' ' ' <"$CALLS")"
pass "night light, at 4000, 5000 or 5900 K, is never overwritten"

# Night light turned off (6500 K and the identity matrix) or a restarted hyprsunset (6000 K) in a warm room.
for native in 6500 6000; do
  echo 5600 >"$state"; reset "$native"; room 300 4000; "$auto" --once
  [[ $(screen) == 5600 ]] || fail "after $native K the room's white point comes back" "$(screen)"
done
pass "after night light is turned off, or hyprsunset restarts, the room's white point comes back"

rm -f "$SCREEN"; : >"$CALLS"; room 300 2700; "$auto" --once
for _ in $(seq 30); do grep -q '^start' "$CALLS" && break; /usr/bin/sleep 0.1; done
grep -q '^start -- hyprsunset' "$CALLS" || fail "a missing hyprsunset is started" "$(tr '\n' ' ' <"$CALLS")"
pass "hyprsunset is started when it does not answer"

# The loop: turning the toggle off, or stopping the unit, puts native white back.
reset 6000; room 300 2700; rm -f "$state"
"$auto" & loop=$!
for _ in $(seq 50); do [[ $(screen) == 4800 ]] && break; /usr/bin/sleep 0.1; done
[[ $(screen) == 4800 ]] || fail "the loop warms the screen" "$(screen)"
rm -f "$toggle"
for _ in $(seq 60); do kill -0 "$loop" 2>/dev/null || break; /usr/bin/sleep 0.1; done
kill -0 "$loop" 2>/dev/null && fail "the loop stops when the toggle goes"
loop=""
[[ $(screen) == 6500 ]] && grep -qx identity "$CALLS" || fail "turning it off restores native white" "$(screen)"
pass "removing the toggle stops the loop and restores native white"

: >"$toggle"; reset 6000
"$auto" & loop=$!
for _ in $(seq 50); do [[ $(screen) == 4800 ]] && break; /usr/bin/sleep 0.1; done
kill -TERM "$loop"; wait "$loop" || true; loop=""
[[ $(screen) == 6500 ]] || fail "stopping the unit restores native white" "$(screen)"
echo 4000 >"$SCREEN"; echo 4800 >"$state"
"$auto" & loop=$!
/usr/bin/sleep 0.5; kill -TERM "$loop"; wait "$loop" || true; loop=""
[[ $(screen) == 4000 ]] || fail "stopping leaves night light alone" "$(screen)"
pass "stopping the unit restores native white, but never undoes night light"
