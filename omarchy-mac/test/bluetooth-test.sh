#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
[[ ${PLATFORM:-apple-silicon} != "error" ]] || exit 1
echo "${PLATFORM:-apple-silicon}"
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
[[ ${PCI_ERROR:-0} != "1" ]] || exit 1
echo "01:00.1 Broadcom Bluetooth [14e4:${BLUETOOTH_ID:-5f69}]"
STUB
chmod +x "$work/bin/"*
root=$work/root
"$ROOT/install" "$root"
PATH="$work/bin:$PATH" "$root/usr/bin/omarchy-mac-setup-system" "$root"
unit=omarchy-bluetooth-resume-fix.service
[[ -f $root/usr/lib/systemd/system/$unit ]] || fail 'the package ships the Bluetooth vendor unit'
for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
  link="$root/etc/systemd/system/$target.target.wants/$unit"
  [[ $(readlink "$link") == /usr/lib/systemd/system/$unit ]] || fail 'supported Macs enable the vendor recovery unit'
done
pass 'a staged BCM4378 Mac enables Bluetooth recovery through package setup'

[[ -x $root/usr/bin/omarchy-bluetooth-resume-fix ]] || fail 'the installed recovery command ships'
sed "s|/usr/lib/omarchy-mac/|$root/usr/lib/omarchy-mac/|g" "$root/usr/bin/omarchy-bluetooth-resume-fix" >"$work/recover"
chmod +x "$work/recover"
cat >"$work/bin/rfkill" <<'STUB'
#!/bin/bash
[[ ${RFKILL_FAILS:-0} != "1" ]] || exit 3
if [[ ${RADIO_SWITCH:-0} == "1" && -f $RADIO_READ ]]; then
  echo 'hci0 blocked'
else
  [[ -z ${RADIO_STATE-unblocked} ]] || printf 'hci0 %s\n' "${RADIO_STATE-unblocked}"
fi
echo 'hci1 unblocked'
touch "$RADIO_READ"
STUB
cat >"$work/bin/journalctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$JOURNAL_CALLS"
[[ ${JOURNAL_FAILS:-0} != "1" ]] || exit 3
if [[ $* == *"--show-cursor"* ]]; then
  [[ ${NO_CURSOR:-0} == "1" ]] || echo '-- cursor: s=test;i=suspend-entry'
elif [[ $* == *'--after-cursor s=test;i=suspend-entry'* && ${WEDGE:-0} == "1" ]]; then
  echo "Bluetooth: ${TIMED_OUT_CONTROLLER:-hci0}: command 0x0c01 tx timeout"
  [[ ${MISSING_CONTROLLER:-0} != "1" ]] || rm -rf "$OMARCHY_BLUETOOTH_CLASS_DIR/hci0"
elif [[ $* == *"--since"* && ${SINCE_EMPTY:-0} != "1" && ${WEDGE:-0} == "1" ]]; then
  echo "Bluetooth: ${TIMED_OUT_CONTROLLER:-hci0}: command 0x0c01 tx timeout"
elif [[ $* != *"--after-cursor"* && $* != *"--since"* && ${STALE:-0} == "1" ]]; then
  echo 'Bluetooth: hci0: command 0x0c01 tx timeout'
fi
STUB
printf '#!/bin/bash\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*
driver=$work/driver
controllers=$work/controllers
mkdir -p "$driver/0000:01:00.1" "$controllers/hci0"
ln -s "$driver/0000:01:00.1" "$controllers/hci0/device"
: >"$driver/unbind"
: >"$driver/bind"
export JOURNAL_CALLS=$work/journal-calls RADIO_READ=$work/radio-read
WEDGE=1 PATH="$work/bin:$PATH" OMARCHY_BLUETOOTH_DRIVER_DIR=$driver OMARCHY_BLUETOOTH_CLASS_DIR=$controllers \
  "$work/recover" >"$work/output"
[[ $(<"$driver/unbind") == "0000:01:00.1" && $(<"$driver/bind") == "0000:01:00.1" ]] || fail 'a confirmed resume wedge rebinds only the Bluetooth function'
pass 'the installed command recovers timeouts logged during device resume'

run_recovery() {
  rm -rf "$driver" "$controllers"
  mkdir -p "$driver" "$controllers"
  [[ ${UNBOUND:-0} == "1" ]] || mkdir -p "$driver/0000:01:00.1"
  mkdir -p "$controllers/hci0" "$controllers/hci1" "$work/usb-adapter"
  ln -s "$driver/0000:01:00.1" "$controllers/hci0/device"
  ln -s "$work/usb-adapter" "$controllers/hci1/device"
  : >"$driver/unbind"
  : >"$driver/bind"
  : >"$JOURNAL_CALLS"
  rm -f "$RADIO_READ"
  [[ ${UNBIND_FAILS:-0} == "1" ]] && chmod 400 "$driver/unbind"
  [[ ${BIND_FAILS:-0} == "1" ]] && chmod 400 "$driver/bind"
  WEDGE=${WEDGE:-0} NO_CURSOR=${NO_CURSOR:-0} SINCE_EMPTY=${SINCE_EMPTY:-0} STALE=${STALE:-0} \
    RADIO_STATE=${RADIO_STATE-unblocked} RADIO_SWITCH=${RADIO_SWITCH:-0} \
    RFKILL_FAILS=${RFKILL_FAILS:-0} JOURNAL_FAILS=${JOURNAL_FAILS:-0} \
    TIMED_OUT_CONTROLLER=${TIMED_OUT_CONTROLLER:-hci0} MISSING_CONTROLLER=${MISSING_CONTROLLER:-0} \
    PLATFORM=${PLATFORM:-apple-silicon} BLUETOOTH_ID=${BLUETOOTH_ID:-5f69} PCI_ERROR=${PCI_ERROR:-0} \
    PATH="$work/bin:$PATH" OMARCHY_BLUETOOTH_DRIVER_DIR=$driver OMARCHY_BLUETOOTH_CLASS_DIR=$controllers \
    "$work/recover" >"$work/output" 2>&1
}

run_recovery
[[ ! -s $driver/unbind && ! -s $driver/bind ]] || fail 'a healthy resume leaves the driver alone'
pass 'a healthy controller is left alone'
for spec in 'blocked' ''; do
  RADIO_STATE=$spec WEDGE=1 run_recovery
  [[ ! -s $driver/unbind ]] || fail 'a disabled or absent radio is never rebound'
done
RADIO_SWITCH=1 WEDGE=1 run_recovery
[[ ! -s $driver/unbind ]] || fail 'a radio disabled while watching is never rebound'
pass 'radio disablement is respected before and during recovery'
UNBOUND=1 WEDGE=1 run_recovery
[[ ! -s $driver/unbind ]] || fail 'an unbound controller is not guessed'
pass 'an unbound driver is reported without a reset'
WEDGE=1 SINCE_EMPTY=1 run_recovery
[[ -s $driver/unbind ]] || fail 'a cursor survives the clock changing'
NO_CURSOR=1 WEDGE=1 run_recovery
[[ -s $driver/unbind ]] || fail 'a missing suspend cursor uses the bounded fallback'
NO_CURSOR=1 SINCE_EMPTY=1 STALE=1 run_recovery
[[ ! -s $driver/unbind ]] || fail 'stale journal history cannot confirm a fresh wedge'
pass 'cursor, bounded fallback and stale-history behavior'
TIMED_OUT_CONTROLLER=hci1 WEDGE=1 run_recovery
[[ ! -s $driver/unbind ]] || fail 'another Bluetooth adapter cannot reset the internal controller'
pass 'timeouts are correlated with the selected PCI controller'
if RFKILL_FAILS=1 run_recovery; then fail 'an unreadable radio state is not a successful disabled-radio result'; fi
if JOURNAL_FAILS=1 run_recovery; then fail 'an unreadable journal is not a successful healthy resume'; fi
pass 'observation failures remain visible'
if UNBIND_FAILS=1 WEDGE=1 run_recovery; then fail 'an unbind failure exits nonzero'; fi
grep -Fq 'Failed to unbind' "$work/output" || fail 'an unbind failure is diagnosed'
if BIND_FAILS=1 WEDGE=1 run_recovery; then fail 'a bind failure exits nonzero'; fi
grep -Fq 'Failed to bind' "$work/output" || fail 'a bind failure is diagnosed'
if MISSING_CONTROLLER=1 WEDGE=1 run_recovery; then fail 'a missing controller after rebind exits nonzero'; fi
grep -Fq 'Controller still missing' "$work/output" || fail 'a controller-return failure is diagnosed'
pass 'unbind, bind and controller-return failures are observable'
for spec in 'generic 5f69' 'generic-aarch64 5f71' 'qualcomm 5f69' 'apple-silicon 5f72' 'apple-silicon 0000'; do
  read -r PLATFORM BLUETOOTH_ID <<<"$spec"
  WEDGE=1 run_recovery
  [[ ! -s $driver/unbind && ! -s $JOURNAL_CALLS ]] || fail 'excluded hardware stops before recovery'
done
unset PLATFORM BLUETOOTH_ID
if PLATFORM=error WEDGE=1 run_recovery; then fail 'a detector failure is reported'; fi
[[ ! -s $driver/unbind ]] || fail 'a detector failure does not rebind'
if PCI_ERROR=1 WEDGE=1 run_recovery; then fail 'PCI detection failure is reported'; fi
pass 'platform and chipset gates protect the recovery command'

setup() {
  PLATFORM=${PLATFORM:-apple-silicon} BLUETOOTH_ID=${BLUETOOTH_ID:-5f69} \
    PATH="$work/bin:$PATH" "$root/usr/bin/omarchy-mac-setup-system" "$root" >/dev/null
}
systemctl --root="$root" disable "$unit" >/dev/null 2>&1
setup
[[ ! -e $root/etc/systemd/system/suspend.target.wants/$unit ]] || fail 'repeat setup preserves an explicit disable'
pass 'successful setup records enablement once'
for override in mask custom; do
  root=$work/$override
  "$ROOT/install" "$root"
  mkdir -p "$root/etc/systemd/system"
  if [[ $override == "mask" ]]; then
    ln -s /dev/null "$root/etc/systemd/system/$unit"
  else
    echo 'custom unit' >"$root/etc/systemd/system/$unit"
  fi
  setup
  [[ ! -e $root/etc/systemd/system/suspend.target.wants/$unit ]] || fail 'overrides prevent vendor enablement'
  [[ ! -e $root/var/lib/omarchy-mac/bluetooth-configured ]] || fail 'an override is not recorded as vendor setup'
done
pass 'masks and custom units survive package setup'
for spec in 'apple-silicon 5f71 1' 'apple-silicon 5f72 0' 'generic 5f69 0'; do
  read -r PLATFORM BLUETOOTH_ID enabled <<<"$spec"
  root=$work/setup-$PLATFORM-$BLUETOOTH_ID
  "$ROOT/install" "$root"
  setup
  if (( enabled )); then
    [[ -f $root/var/lib/omarchy-mac/bluetooth-configured ]] || fail 'BCM4387 is enabled on Apple Silicon'
  else
    [[ ! -e $root/etc/systemd/system/suspend.target.wants/$unit ]] || fail 'excluded setup stays disabled'
  fi
done
unset PLATFORM BLUETOOTH_ID
pass 'setup follows the source PR chipset scope'

root=$work/retry
"$ROOT/install" "$root"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
if [[ ${SYSTEMCTL_FAIL:-0} == "1" && $* == *'enable omarchy-bluetooth-resume-fix.service'* ]]; then
  exit 42
fi
exec /usr/bin/systemctl "$@"
STUB
chmod +x "$work/bin/systemctl"
if SYSTEMCTL_FAIL=1 setup; then fail 'failed first enablement must fail setup'; fi
[[ ! -e $root/var/lib/omarchy-mac/bluetooth-configured ]] || fail 'failed enablement stays pending'
setup
[[ -f $root/var/lib/omarchy-mac/bluetooth-configured ]] || fail 'a later enablement succeeds'
pass 'failed enablement is retryable'
