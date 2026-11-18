#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
helper="$work/root/usr/lib/omarchy-mac/wait-for-display"
# Root and unprivileged tests both run the installed helper against fixture roots.
sed -i "s|^proc=/proc$|proc=$work/proc|;s|^dev=/dev$|dev=$work/dev|;s|^sys=/sys$|sys=$work/sys|" "$helper"
export OMARCHY_PROC_ROOT="$work/proc" OMARCHY_DEV_ROOT="$work/dev" OMARCHY_SYS_ROOT="$work/sys"
mkdir -p "$work/bin" "$work/proc/device-tree" "$work/dev/dri" "$work/sys/class/drm"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-1} == "1" ]]
STUB
cat >"$work/bin/udevadm" <<'STUB'
#!/bin/bash
[[ $* == 'settle --timeout=10' ]] || exit 2
printf 'settle\n' >>"$SETTLE_LOG"
exit "${SETTLE_STATUS:-0}"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" SETTLE_LOG="$work/settle.log"
compatibility() { printf '%s\0' "$@" >"$work/proc/device-tree/compatible"; }
parameter() { printf '%s\n' "$*" >"$work/proc/cmdline"; }
driver() {
  mkdir -p "$work/sys/class/drm/$1/device" "$work/sys/drivers/$2"
  ln -sfn "$work/sys/drivers/$2" "$work/sys/class/drm/$1/device/driver"
}
waiting() {
  local status=0
  timeout 0.3 "$helper" >"$work/output" || status=$?
  (( status == 124 )) || fail "$1" "status=$status"
}
handoff() {
  mkdir -p "$work/proc/device-tree/aliases" "$work/proc/device-tree/soc/gpu@40a400000" \
    "$work/proc/device-tree/soc/dcp@386c00000"
  printf '/soc/gpu@40a400000\0' >"$work/proc/device-tree/aliases/gpu"
  printf '%s\0' "$1" >"$work/proc/device-tree/soc/gpu@40a400000/status"
  if [[ $2 == marker ]]; then
    : >"$work/proc/device-tree/soc/dcp@386c00000/apple,t6031-handoff"
  else
    rm -f "$work/proc/device-tree/soc/dcp@386c00000/apple,t6031-handoff"
  fi
}
compatibility apple,j514c apple,t6031
parameter
# The display-subsystem node is present, so falling into the old 10 s wait would time out here.
mkdir -p "$work/proc/device-tree/soc/display-subsystem"
handoff disabled marker
timeout 2 "$helper" || fail 'a GPU the loader left disabled waits for nothing'
handoff okay none
timeout 2 "$helper" || fail 'no display handoff marker waits for nothing'
handoff okay marker
for value in 0 n no false OFF off disable; do
  parameter quiet apple_t6031_display.enable=$value splash
  timeout 2 "$helper" || fail "apple_t6031_display.enable=$value waits for nothing"
done
parameter apple_t6031_display.enable=1 apple_t6031_display.enable=0
timeout 2 "$helper" || fail 'the last apple_t6031_display.enable=0 wins'
parameter 'apple_t6031_display.enable="0"'
timeout 2 "$helper" || fail 'a quoted apple_t6031_display.enable="0" waits for nothing'
parameter '"apple_t6031_display.enable=0"'
timeout 2 "$helper" || fail 'a quoted "apple_t6031_display.enable=0" waits for nothing'
parameter apple_t6031_display.enable=0 apple_t6031_display.enable=bogus
timeout 2 "$helper" || fail 'an invalid later value keeps the earlier off'
parameter apple_t6031_display.enable=0 apple_t6031_display.enable
waiting 'a later bare apple_t6031_display.enable turns it back on'
parameter apple-t6031-display.enable=0
timeout 2 "$helper" || fail 'hyphens match underscores in the switch name'
parameter 'note="text apple_t6031_display.enable=0"'
waiting 'the switch quoted inside another parameter is only text'
parameter -- apple_t6031_display.enable=0
waiting 'the switch after -- belongs to init'
for value in 1 y yes on true; do
  parameter apple_t6031_display.enable=0 apple_t6031_display.enable=$value
  waiting "a final apple_t6031_display.enable=$value still waits"
done
parameter
rmdir "$work/proc/device-tree/soc/display-subsystem"
pass 'only a handed-over GPU and display, not disabled by the owner, enter the native wait'
APPLE=0 timeout 2 "$helper" || fail 'other platforms never enter the J514C wait'
waiting 'J514C waits for native graphics without an enable parameter'
parameter
compatibility apple,j514c apple,t6034
timeout 2 "$helper" || fail 'J514C name on another SoC never enters native wait'
compatibility apple,j516c apple,t6031
timeout 2 "$helper" || fail 'another T6031 board never enters native wait'
compatibility apple,j514c apple,t6031
pass 'exact board, SoC and platform gates; no enable parameter'

driver card0 simpledrm
driver renderD128 asahi-g15
touch "$work/dev/dri/renderD128"
waiting 'simpledrm is not the native display'
driver card0 apple-drm
driver renderD128 other-gpu
waiting 'another render driver is not the native GPU'
driver renderD128 asahi-g15
rm "$work/dev/dri/renderD128"
waiting 'sysfs alone is insufficient before the render device exists'
touch "$work/dev/dri/renderD128"
SETTLE_STATUS=1 timeout 2 "$helper" >"$work/output" || fail 'settle failure never fails the greeter'
grep -q 'native_display=true native_gpu=true' "$work/output" || fail 'native readiness is logged'
[[ -s $SETTLE_LOG ]] || fail 'ready devices pass through bounded udev settle'
pass 'native driver and device checks; bounded settle is nonfatal'

rm "$work/dev/dri/renderD128"
"$helper" >"$work/output" &
waiter=$!
sleep 0.2
kill -0 "$waiter" 2>/dev/null || fail 'the greeter waits while native GPU is absent'
touch "$work/dev/dri/renderD128"
wait "$waiter" || fail 'late GPU readiness permits the greeter'
pass 'the greeter proceeds when native devices arrive'

rm "$work/dev/dri/renderD128"
timeout 35 "$helper" >"$work/output" || fail 'missing native GPU reaches a bounded nonfatal timeout'
grep -q 'native_display=true native_gpu=false' "$work/output" || fail 'timeout records missing GPU'
pass 'a missing native GPU never blocks login indefinitely'
