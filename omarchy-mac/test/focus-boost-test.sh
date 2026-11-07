#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
unit="$stage/usr/lib/systemd/system/omarchy-mac-focus-boost.service"
[[ -x $stage/usr/bin/omarchy-mac-focus-boost && -f $unit ]] || fail 'stages the command and unit'
grep -Fxq 'ConditionFirmware=device-tree-compatible(apple,j616c)' "$unit" || fail 'the unit runs on the J616C only'
grep -Fxq 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$unit" || fail 'the unit stays behind the platform detector'
[[ -L ${unit%/*}/multi-user.target.wants/omarchy-mac-focus-boost.service ]] || fail 'the vendor wants link enables the unit'
pass 'stages a focus boost service gated to the J616C'

fixture="$work/omarchy_mac_focus_boost.py"
sed -e "s|/run/user/\*/hypr|$work/run/user/*/hypr|" -e "s|/sys/fs/cgroup|$work/cgroup|" \
  -e "s|/proc/bus/input/devices|$work/input-devices|" -e "s|\"/dev/input\"|\"$work/input\"|" \
  "$ROOT/bin/omarchy-mac-focus-boost" >"$fixture"
mkdir -p "$work/run/user/1000/hypr/old" "$work/run/user/1000/hypr/new"
: >"$work/run/user/1000/hypr/old/.socket2.sock"
: >"$work/run/user/1000/hypr/new/.socket2.sock"
touch -d '2000-01-01' "$work/run/user/1000/hypr/old/.socket2.sock"
apps="$work/cgroup/user.slice/app.slice"
mkdir -p "$apps/app-flatpak-browser-11.scope" "$apps/app-flatpak-browser-2a.scope" "$apps/app-other-1.scope" "$apps/plain.service"
printf '10\n11\n' >"$apps/app-flatpak-browser-11.scope/cgroup.procs"
printf '12\n' >"$apps/app-flatpak-browser-2a.scope/cgroup.procs"
printf 'usage_usec 1500\nuser_usec 1000\n' >"$apps/app-flatpak-browser-11.scope/cpu.stat"
printf 'usage_usec 500\nuser_usec 100\n' >"$apps/app-flatpak-browser-2a.scope/cpu.stat"
cat >"$work/input-devices" <<'DEVICES'
I: Bus=0003
N: Name="Apple Internal Keyboard / Trackpad"
H: Handlers=sysrq kbd leds event3

I: Bus=0019
N: Name="Lid Switch"
H: Handlers=event1

I: Bus=0019
N: Name="Headphone Jack"
H: Handlers=event2

I: Bus=0003
N: Name="USB Mouse"
H: Handlers=mouse0 event7
DEVICES
python3 -I - "$work" <<'PY'
import importlib.util
import os
import sys
work = sys.argv[1]
spec = importlib.util.spec_from_file_location("focus", f"{work}/omarchy_mac_focus_boost.py")
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)

assert focus.session() == (os.getuid(), f"{work}/run/user/1000/hypr/new"), "takes the newest session"
assert focus.input_devices() == {f"{work}/input/event3", f"{work}/input/event7"}, "keyboards and mice only"
parent = "/user.slice/app.slice"
siblings = focus.app_cgroups(f"{parent}/app-flatpak-browser-11.scope")
assert siblings == [f"{parent}/app-flatpak-browser-11.scope", f"{parent}/app-flatpak-browser-2a.scope"], siblings
assert focus.app_cgroups(f"{parent}/plain.service") == [f"{parent}/plain.service"], "a plain unit stands alone"
assert focus.app_cgroups(None) == [], "no cgroup means no app"
assert focus.app_pids(siblings) == {10, 11, 12}, "every process of the app"
assert focus.app_pids([f"{parent}/gone.scope"]) == set(), "a closed app has no processes"
assert focus.app_cpu_usec(siblings) == 2000, "CPU time of the whole app"
PY
pass 'follows the newest session, the input devices and every cgroup of the app'
