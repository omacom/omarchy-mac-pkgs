#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
unit="$stage/usr/lib/systemd/system/omarchy-mac-fan.service"
[[ -x $stage/usr/bin/omarchy-mac-fan && -f $unit ]] || fail 'stages the command and unit'
grep -Fxq 'ConditionFirmware=device-tree-compatible(apple,j616c)' "$unit" || fail 'the unit runs on the J616C only'
[[ -L ${unit%/*}/multi-user.target.wants/omarchy-mac-fan.service ]] || fail 'the vendor wants link enables the unit'
pass 'stages a fan service gated to the J616C'

mkdir -p "$work/bin"
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH"
fixture="$work/omarchy_mac_fan.py"
sed -e "s|/sys/class/hwmon|$work/sys/hwmon|" -e "s|/sys/class/thermal|$work/sys/thermal|" \
  -e "s|/var/lib/omarchy-mac-fan|$work/var|" -e "s|/run/omarchy-mac-fan|$work/run|" \
  "$ROOT/bin/omarchy-mac-fan" >"$fixture"
mkdir -p "$work/var" "$work/run" "$work/sys/hwmon/hwmon0" "$work/sys/thermal/thermal_zone0" "$work/sys/thermal/thermal_zone1"
hwmon="$work/sys/hwmon/hwmon0"
printf 'macsmc_hwmon\n' >"$hwmon/name"
printf '0\n' >"$hwmon/fan1_target"
printf '1350\n' >"$hwmon/fan1_min"
printf '5777\n' >"$hwmon/fan1_max"
printf 'Battery Hotspot\n' >"$hwmon/temp1_label"
printf '30000\n' >"$hwmon/temp1_input"
printf 'macsmc-battery\n' >"$work/sys/thermal/thermal_zone0/type"
printf 'cpu-die-thermal\n' >"$work/sys/thermal/thermal_zone1/type"
python3 -I - "$work" <<'PY'
import importlib.util
import pathlib
import sys
work = sys.argv[1]
spec = importlib.util.spec_from_file_location("fan", f"{work}/omarchy_mac_fan.py")
fan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fan)

assert fan.get_mode() == "auto", "no mode file means auto"
assert fan.find_die_zone().endswith("thermal_zone1/temp"), "falls back to the DT die zone"
assert fan.curve(50, fan.BOOST_CURVE) == 1800 and fan.curve(120, fan.BOOST_CURVE) == 5777
assert fan.curve(105, fan.MACOS_CURVE) == 2615

policy = fan.Policy()
assert policy.want("auto", 110, 0, 5000, None, 0) == 0, "auto never takes the fans"
assert policy.want("macos", 90, 0, 0, None, 0) == 0, "below its ladder macos leaves the SMC"
assert policy.want("macos", 106, 0, 0, None, 0) == 3250
assert policy.want("boost", 74, 0, 0, None, 0) == 0
assert policy.want("quiet", 110, 0, 1900, None, 0) == 0, "quiet leaves a quiet SMC alone"
assert policy.want("quiet", 110, 0, 3000, None, 0) == 2000
assert policy.want("quiet", 110, 2000, 2000, "Battery Hotspot", 10) == 0, "a hot battery hands the fans back"
assert policy.want("quiet", 110, 0, 3000, None, 100) == 0, "and they stay handed back"
assert policy.want("quiet", 110, 0, 3000, None, 400) == 2000, "until the guard ends"
policy = fan.Policy()
assert policy.want("macos", 90, 3250, 3250, None, 1) == 3100, "the ramp down is limited"
assert policy.want("macos", 90, 3100, 3100, None, 1 + fan.HOLD_S) == 0, "cool long enough, the SMC gets them back"

hwmon = fan.find_hwmon()
fans = fan.Fans(hwmon)
assert fans.hot_guard() is None
fans.set(9000, 0.0)
assert pathlib.Path(hwmon, "fan1_target").read_text() == "5777", "targets clamp to the fan's maximum"
fans.set(0, 1.0)
assert pathlib.Path(hwmon, "fan1_target").read_text() == "0"
assert fan.main(["fan", "quiet"]) == 0 and fan.get_mode() == "quiet"
assert fan.main(["fan", "cycle"]) == 0 and fan.get_mode() == "boost"
assert fan.main(["fan", "nonsense"]) == 2
assert fan.main(["fan", "status"]) == 0
PY
pass 'modes follow their curves, leave the SMC below them and honour the guards'
rm "$hwmon/fan1_target"
python3 -I "$fixture" daemon >"$work/out"
grep -q 'no fan targets' "$work/out" || fail 'a device tree without fan targets exits cleanly'
pass 'without fan targets the daemon logs it and exits'
