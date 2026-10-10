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
unit=omarchy-bluetooth-resume-fix.service
[[ -f $root/usr/lib/systemd/system/$unit ]] || fail 'the package ships the Bluetooth vendor unit'
link=$root/usr/lib/systemd/system/suspend.target.wants/$unit
[[ $(readlink "$link") == "../$unit" && -f $link ]] || fail 'the package wants the unit after every suspend'
grep -qx 'WantedBy=suspend.target' "$root/usr/lib/systemd/system/$unit" || fail 'the unit installs into suspend.target'
if grep -Eq 'hibernate|hybrid-sleep' "$root/usr/lib/systemd/system/$unit"; then
  fail 'hibernation is not a path the recovery handles'
fi
pass 'the package runs Bluetooth recovery after every suspend, on installs and upgrades alike'

printf '[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"$root/usr/lib/systemd/system/speakersafetyd.service"
PATH="$work/bin:$PATH" "$root/usr/bin/omarchy-mac-setup-system" "$root"
[[ ! -e $root/etc/systemd/system/suspend.target.wants/$unit && ! -e $root/var/lib/omarchy-mac/bluetooth-configured ]] ||
  fail 'setup leaves Bluetooth enablement to the package'
rm -rf "$root"
"$ROOT/install" "$root"
printf '[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >"$root/usr/lib/systemd/system/speakersafetyd.service"
PCI_ERROR=1 PATH="$work/bin:$PATH" "$root/usr/bin/omarchy-mac-setup-system" "$root" >/dev/null ||
  fail 'a Bluetooth detection failure does not fail setup'
[[ -f $root/var/lib/omarchy-mac/speaker-safety-configured ]] || fail 'setup after a Bluetooth detection failure still sets up the speakers'
pass 'system setup has no Bluetooth step that can stop the rest'

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
# The kernel journal of this boot, one "tick|cursor|message" line per entry: an
# entry appears once the stub clock reaches its tick, and an "old-" cursor was
# logged before the service started, so --since leaves it out.
cat >"$work/bin/journalctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$JOURNAL_CALLS"
[[ ${JOURNAL_FAILS:-0} != "1" ]] || exit 3
tick=$(<"$TICK")
pattern= count= after= since=0 show_cursor=0
while (( $# )); do
  case $1 in
    -g) pattern=$2; shift ;;
    -n) count=$2; shift ;;
    -o) shift ;;
    --after-cursor) after=$2; shift ;;
    --since) since=1; shift ;;
    --show-cursor) show_cursor=1 ;;
  esac
  shift
done
cursors=() messages=()
passed=1
[[ -z $after ]] || passed=0
while IFS='|' read -r at cursor message; do
  (( tick >= at )) || continue
  if (( ! passed )); then
    [[ $cursor != "$after" ]] || passed=1
    continue
  fi
  [[ $since == 0 || $cursor != old-* ]] || continue
  [[ -z $pattern || $message =~ $pattern ]] || continue
  cursors+=("$cursor") messages+=("$message")
done <"$JOURNAL_FILE"
first=0
[[ -z $count ]] || (( ${#messages[@]} <= count )) || first=$(( ${#messages[@]} - count ))
for (( i = first; i < ${#messages[@]}; i++ )); do echo "${messages[i]}"; done
if [[ -n $pattern ]] && (( ${#messages[@]} == 0 )); then
  exit 1
fi
(( ! show_cursor || ${#cursors[@]} == 0 )) || echo "-- cursor: ${cursors[-1]}"
STUB
# Each sleep advances the stub clock; the kernel's suspend count can change at a tick.
cat >"$work/bin/sleep" <<'STUB'
#!/bin/bash
tick=$(( $(<"$TICK") + 1 ))
echo "$tick" >"$TICK"
if [[ -n ${STATS_AT:-} && $tick == "${STATS_AT%%:*}" ]]; then
  echo "${STATS_AT#*:}" >"$OMARCHY_SUSPEND_STATS_DIR/success"
fi
[[ ${SLEEP_REAL:-0} != "1" ]] || /bin/sleep 0.05
exit 0
STUB
chmod +x "$work/bin/"*
driver=$work/driver
controllers=$work/controllers
stats=$work/stats
export JOURNAL_CALLS=$work/journal-calls RADIO_READ=$work/radio-read JOURNAL_FILE=$work/journal TICK=$work/tick

# The journal for a run. Default: this cycle's entry and exit, with timeouts
# from hci0 logged during device resume, before the service started.
journal() {
  cat >"$JOURNAL_FILE"
}
wedged_resume() {
  journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-t1|Bluetooth: hci0: command 0x0c01 tx timeout
0|old-x1|PM: suspend exit
LOG
}
healthy_resume() {
  journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-x1|PM: suspend exit
LOG
}

run_recovery() {
  rm -rf "$driver" "$controllers" "$stats"
  mkdir -p "$driver" "$controllers" "$stats"
  [[ ${UNBOUND:-0} == "1" ]] || mkdir -p "$driver/0000:01:00.1"
  mkdir -p "$controllers/hci0" "$controllers/hci1" "$work/usb-adapter"
  ln -s "$driver/0000:01:00.1" "$controllers/hci0/device"
  ln -s "$work/usb-adapter" "$controllers/hci1/device"
  if [[ ${NO_STATS:-0} != "1" ]]; then
    echo "${SUCCESS:-1}" >"$stats/success"
    echo 0 >"$stats/fail"
  fi
  : >"$JOURNAL_CALLS"
  echo 0 >"$TICK"
  rm -f "$RADIO_READ"
  reader=
  if [[ ${REBIND_FIFO:-0} == "1" ]]; then
    # Like sysfs: unbinding removes hci0, and binding brings it back unless it stays missing.
    mkfifo "$driver/unbind" "$driver/bind"
    (
      read -r _ <"$driver/unbind"
      rm -rf "$controllers/hci0"
      read -r _ <"$driver/bind"
      if [[ ${STAYS_MISSING:-0} != "1" ]]; then
        mkdir -p "$controllers/hci0"
        ln -s "$driver/0000:01:00.1" "$controllers/hci0/device"
      fi
    ) &
    reader=$!
  else
    : >"$driver/unbind"
    : >"$driver/bind"
    [[ ${UNBIND_FAILS:-0} != "1" ]] || chmod 400 "$driver/unbind"
    [[ ${BIND_FAILS:-0} != "1" ]] || chmod 400 "$driver/bind"
  fi
  status=0
  RADIO_STATE=${RADIO_STATE-unblocked} RADIO_SWITCH=${RADIO_SWITCH:-0} \
    RFKILL_FAILS=${RFKILL_FAILS:-0} JOURNAL_FAILS=${JOURNAL_FAILS:-0} \
    STATS_AT=${STATS_AT:-} SLEEP_REAL=${REBIND_FIFO:-0} \
    PLATFORM=${PLATFORM:-apple-silicon} BLUETOOTH_ID=${BLUETOOTH_ID:-5f69} PCI_ERROR=${PCI_ERROR:-0} \
    PATH="$work/bin:$PATH" OMARCHY_BLUETOOTH_DRIVER_DIR=$driver OMARCHY_BLUETOOTH_CLASS_DIR=$controllers \
    OMARCHY_SUSPEND_STATS_DIR=$stats "$work/recover" >"$work/output" 2>&1 || status=$?
  if [[ -n $reader ]]; then
    kill "$reader" 2>/dev/null || true
    wait "$reader" 2>/dev/null || true
  fi
  return "$status"
}
rebound() {
  [[ -p $driver/unbind ]] && grep -Fq 'rebinding hci_bcm4377' "$work/output" && return 0
  [[ -f $driver/unbind && $(<"$driver/unbind") == "0000:01:00.1" && $(<"$driver/bind") == "0000:01:00.1" ]]
}

wedged_resume
run_recovery
rebound || fail 'timeouts from this resume rebind only the Bluetooth function'
pass 'the installed command recovers timeouts logged during device resume'

healthy_resume
run_recovery
! rebound || fail 'a resume without timeouts leaves the driver alone'
grep -Fq 'No HCI command timeout from hci0' "$work/output" || fail 'a quiet resume says what it saw, not that the controller is healthy'
pass 'a controller with no timeout is left alone'
for spec in 'blocked' ''; do
  wedged_resume
  RADIO_STATE=$spec run_recovery
  ! rebound || fail 'a disabled or absent radio is never rebound'
done
wedged_resume
RADIO_SWITCH=1 run_recovery
! rebound || fail 'a radio disabled while watching is never rebound'
pass 'radio disablement is respected before and during recovery'
wedged_resume
UNBOUND=1 run_recovery
! rebound || fail 'an unbound controller is not guessed'
pass 'an unbound driver is reported without a reset'

# Timeouts from an earlier cycle, after the cursor of that cycle's entry but
# before this suspend, never count for this one.
journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-t1|Bluetooth: hci0: command 0x0c01 tx timeout
0|old-x1|PM: suspend exit
0|old-e2|PM: suspend entry (s2idle)
0|old-x2|PM: suspend exit
LOG
SUCCESS=2 run_recovery
! rebound || fail 'timeouts before this suspend do not rebind'
# journald still catching up: the kernel counted a second suspend whose entry
# reaches the journal only at tick 3, so its latest entry is the first cycle's.
journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-t1|Bluetooth: hci0: command 0x0c01 tx timeout
0|old-x1|PM: suspend exit
3|old-e2|PM: suspend entry (s2idle)
3|old-x2|PM: suspend exit
LOG
SUCCESS=2 run_recovery
! rebound || fail 'a lagging journal does not hand this cycle the previous cycle timeouts'
grep -Fq 'after-cursor old-e2' "$JOURNAL_CALLS" || fail 'the watch starts from the entry the kernel counted'
# The entry never arrives: watch a bounded window from now instead.
SUCCESS=3 run_recovery
! rebound || fail 'an entry that never arrives falls back without reading old timeouts'
grep -Fq 'watching from now instead' "$work/output" || fail 'the fallback is reported'
pass 'the watch is tied to the current suspend cycle'

wedged_resume
NO_STATS=1 run_recovery
rebound || fail 'without suspend statistics the latest entry this boot is used'
journal <<'LOG'
0|late-t1|Bluetooth: hci0: command 0x0c01 tx timeout
LOG
SUCCESS=0 run_recovery
rebound || fail 'a missing suspend entry uses the bounded fallback'
journal <<'LOG'
0|old-t1|Bluetooth: hci0: command 0x0c01 tx timeout
LOG
SUCCESS=0 run_recovery
! rebound || fail 'stale journal history cannot report a fresh timeout'
grep -q -- '-kqb' "$JOURNAL_CALLS" || fail 'journal reads stay within this boot'
pass 'cursor, bounded fallback and stale-history behavior'

# A second suspend at tick 15 of the 20-pass watch, with a timeout logged at
# tick 30: the watch follows the new resume and restarts its 20 passes.
journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-x1|PM: suspend exit
15|late-e2|PM: suspend entry (s2idle)
15|late-x2|PM: suspend exit
30|late-t2|Bluetooth: hci0: command 0x0c01 tx timeout
LOG
STATS_AT=15:2 run_recovery
rebound || fail 'a timeout after a second suspend during the watch is recovered'
grep -Fq 'Suspended again while watching' "$work/output" || fail 'the watch reports following the newer resume'
grep -Fq 'after-cursor late-e2' "$JOURNAL_CALLS" || fail 'the watch moves to the newer suspend entry'
pass 'a suspend during the watch moves it to the latest resume'

journal <<'LOG'
0|old-e1|PM: suspend entry (s2idle)
0|old-t1|Bluetooth: hci1: command 0x0c01 tx timeout
0|old-x1|PM: suspend exit
LOG
run_recovery
! rebound || fail 'another Bluetooth adapter cannot reset the internal controller'
pass 'timeouts are correlated with the selected PCI controller'

wedged_resume
REBIND_FIFO=1 run_recovery || fail 'a controller that leaves on unbind and returns on bind is recovered'
grep -Fq 'Controller back' "$work/output" || fail 'the return of the controller is reported'
wedged_resume
if REBIND_FIFO=1 STAYS_MISSING=1 run_recovery; then fail 'a controller that never returns after rebind exits nonzero'; fi
grep -Fq 'Controller still missing' "$work/output" || fail 'a controller-return failure is diagnosed'
pass 'hci0 leaves on unbind and must return on bind'

wedged_resume
if UNBIND_FAILS=1 run_recovery; then fail 'an unbind failure exits nonzero'; fi
grep -Fq 'Failed to unbind' "$work/output" || fail 'an unbind failure is diagnosed'
if BIND_FAILS=1 run_recovery; then fail 'a bind failure exits nonzero'; fi
grep -Fq 'Failed to bind' "$work/output" || fail 'a bind failure is diagnosed'
pass 'unbind and bind failures are observable'

for spec in 'generic 5f69' 'generic-aarch64 5f71' 'qualcomm 5f69' 'apple-silicon 0000'; do
  read -r PLATFORM BLUETOOTH_ID <<<"$spec"
  wedged_resume
  PLATFORM=$PLATFORM BLUETOOTH_ID=$BLUETOOTH_ID run_recovery
  [[ ! -s $driver/unbind && ! -s $JOURNAL_CALLS ]] || fail 'excluded hardware stops before recovery'
done
unset PLATFORM BLUETOOTH_ID
for id in 5f69 5f71 5f72; do
  wedged_resume
  BLUETOOTH_ID=$id run_recovery
  rebound || fail "Apple Silicon Bluetooth $id is recovered"
done
if PLATFORM=error run_recovery; then fail 'a detector failure is reported'; fi
[[ ! -s $driver/unbind ]] || fail 'a detector failure does not rebind'
if PCI_ERROR=1 run_recovery; then fail 'PCI detection failure is reported'; fi
pass 'platform and chipset gates protect the recovery command'

healthy_resume
if RFKILL_FAILS=1 run_recovery; then fail 'an unreadable radio state is not a successful disabled-radio result'; fi
if JOURNAL_FAILS=1 run_recovery; then fail 'an unreadable journal is not a successful healthy resume'; fi
pass 'observation failures remain visible'
