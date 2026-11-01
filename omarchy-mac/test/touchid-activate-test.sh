#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Touch ID activates only on the first open of /dev/sep-bio, so a udev rule
# starts a unit that opens it once as soon as the kernel publishes it.
"$ROOT/install" "$work/root"
rule=$work/root/usr/lib/udev/rules.d/94-omarchy-mac-touchid.rules
unit=$work/root/usr/lib/systemd/system/omarchy-mac-touchid-activate.service
script=$work/root/usr/lib/omarchy-mac/touchid-activate
[[ -f $rule && -f $unit && -x $script ]] || fail 'the Touch ID rule, unit and script are staged'
grep -Fxq 'ACTION=="add", SUBSYSTEM=="misc", KERNEL=="sep-bio", TAG+="systemd", ENV{SYSTEMD_WANTS}+="omarchy-mac-touchid-activate.service"' "$rule" ||
  fail 'the rule starts the unit when the Secure Enclave publishes sep-bio, and only then'
[[ $(grep -v '^#' "$rule") != *RUN* ]] || fail 'the rule runs nothing itself'
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/touchid-activate' "$unit" && grep -Fxq 'Type=oneshot' "$unit" &&
  grep -Fxq 'ConditionPathExists=/dev/sep-bio' "$unit" && grep -Fxq 'TimeoutStartSec=60s' "$unit" ||
  fail 'the unit runs the script once, only where the node exists, and within a bounded time'
grep -Fxq 'ConditionPathExists=/var/lib/aurora-sep-keybag.bin' "$unit" ||
  fail 'the unit opens /dev/sep-bio only once the kernel has made the keybag'
grep -Fxq 'ConditionPathExists=/etc/omarchy-mac/touchid-on' "$unit" ||
  fail "the unit opens /dev/sep-bio only once the owner has agreed, whatever loaded the driver"
grep -Fxq 'Before=fprintd.service' "$unit" || fail 'fprintd starts after the unit, not alongside it'
! grep -q '^StandardInput=' "$unit" || fail 'the platform check does not open /dev/sep-bio as well'
! grep -q '^\[Install\]' "$unit" || fail 'the unit needs no enabling: the rule pulls it in'
pass 'the Touch ID rule, unit and script are staged, and the rule alone starts the unit'

# Every condition must hold: with no keybag the unit is skipped, so nothing
# opens the node and latches a failed activation for the boot, and without the
# owner's agreement nothing opens it at all.
if command -v systemd-analyze >/dev/null && systemd-analyze condition --help >/dev/null 2>&1; then
  conditions=$(grep '^ConditionPathExists=' "$unit")
  node=$work/condition/sep-bio
  keybag=$work/condition/aurora-sep-keybag.bin
  agreed=$work/condition/touchid-on
  mkdir -p "$work/condition"
  check() {
    local list=${conditions//\/dev\/sep-bio/$node}
    list=${list//\/var\/lib\/aurora-sep-keybag.bin/$keybag}
    list=${list//\/etc\/omarchy-mac\/touchid-on/$agreed}
    mapfile -t list <<<"$list"
    systemd-analyze condition "${list[@]}" >/dev/null 2>&1
  }
  touch "$node" "$agreed"
  ! check || fail 'a Mac with the node but no keybag skips the unit'
  touch "$keybag"
  check || fail 'an agreed Mac with the node and the keybag runs the unit'
  rm "$agreed"
  ! check || fail 'a Mac whose owner has not agreed skips the unit'
  touch "$agreed"
  rm "$node"
  ! check || fail 'a Mac with a keybag but no node skips the unit'
  pass 'the unit runs only where the owner agreed and both the node and the keybag exist'
fi

# The script, run against a fixture node and sysfs, records "ready" only when
# all four attributes say Touch ID can enrol and match, and the reason otherwise.
fixture=$work/fixture
diag=$fixture/apple_sep/396400000.sep/diag
status=$fixture/run/omarchy-mac/touchid
mkdir -p "$fixture/bin" "$diag"
printf '#!/bin/sh\necho >>"%s"\nexit 0\n' "$fixture/sleeps" >"$fixture/bin/sleep"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
chmod +x "$fixture/bin/sleep" "$fixture/bin/omarchy-hw-apple-silicon"
attributes() {
  printf '%s\n' "$1" >"$diag/touchid"
  printf '%s\n' "$2" >"$diag/sensor_attach"
  printf '%s\n' "$3" >"$diag/restore"
  printf '%s\n' "$4" >"$diag/matching"
}
run_script() {
  : >"$fixture/sleeps"
  (umask 077 && PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_NODE=$fixture/sep-bio OMARCHY_MAC_TOUCHID_DRIVER=$fixture/apple_sep \
    OMARCHY_MAC_TOUCHID_STATUS=$status "$ROOT/lib/touchid-activate" 2>"$fixture/journal")
}
activate() {
  rm -rf "${status%/*}"
  run_script
}
touch "$fixture/sep-bio"
attributes ready attached restored usable
activate || fail 'Touch ID that is ready, attached, restored and usable succeeds'
[[ $(<"$status") == "ready" ]] || fail 'the status reads ready' "$(<"$status")"
[[ $(stat -c %a "$status") == 644 && $(stat -c %a "${status%/*}") == 755 ]] ||
  fail 'the session user can read the status, whatever the umask' "$(stat -c %a "${status%/*}" "$status")"
[[ ! -e $status.new ]] || fail 'the status is replaced in one step'
attributes ready attached empty unverified
activate && [[ $(<"$status") == "ready" ]] || fail 'nothing enrolled yet, behind a guard that has refused nothing, is ready'
rm "$fixture/sep-bio"
attributes ready attached restored usable
activate && [[ $(<"$status") == "ready" ]] || fail 'a node busy with fprintd, on a Touch ID that is ready, is ready'
touch "$fixture/sep-bio"
pass 'the status reads ready only when touchid, sensor_attach, restore and matching all allow enrol and match'

declare -A expected=(
  ["failed unknown unknown unknown"]=failed
  ["ready not-ready unknown unknown"]=not-ready
  ["ready attached unproven usable"]=unproven
  ["ready attached restored blocked"]=blocked
)
for case in "${!expected[@]}"; do
  read -r -a values <<<"$case"
  attributes "${values[@]}"
  ! activate || fail 'a Touch ID that cannot enrol and match fails' "$case"
  [[ $(<"$status") == "${expected[$case]}" ]] || fail 'the status names why' "$case: $(<"$status")"
  [[ $(<"$fixture/journal") == "Touch ID is not ready to enrol and match: "* ]] || fail 'the journal says why' "$case"
  [[ $(wc -l <"$fixture/sleeps") == 0 ]] || fail 'a final answer does not wait' "$case"
done
attributes ready retrying unknown usable
! activate || fail 'an attach still retrying when the wait ends fails'
[[ $(<"$status") == "not-ready" && $(wc -l <"$fixture/sleeps") == 90 ]] ||
  fail 'the script waits 45 s for the later attach round, then records not-ready' "$(<"$status")"
grep -q 'sensor_attach retrying' "$fixture/journal" || fail 'a timeout says what each attribute read'
attributes ready attached restored usable
rm "$diag/matching"
! activate && [[ $(<"$status") == "not-ready" && $(wc -l <"$fixture/sleeps") == 0 ]] ||
  fail 'a kernel without the matching attribute is never ready, and says so at once'
pass 'a Touch ID that cannot enrol and match records why, and only an unsettled attach waits'

# The attributes are read again on every round: the later attach round settles it.
printf '#!/bin/sh\necho >>"%s"\n[ "$(wc -l <"%s")" -lt 3 ] || printf "attached\\n" >"%s"\nexit 0\n' \
  "$fixture/sleeps" "$fixture/sleeps" "$diag/sensor_attach" >"$fixture/bin/sleep"
attributes ready retrying restored usable
activate && [[ $(<"$status") == "ready" && $(wc -l <"$fixture/sleeps") == 3 ]] ||
  fail 'an attach that settles during the wait records ready as soon as it does' "$(wc -l <"$fixture/sleeps")"
printf '#!/bin/sh\necho >>"%s"\nexit 0\n' "$fixture/sleeps" >"$fixture/bin/sleep"
pass 'the wait follows the attach as it settles'

# An update runs the unit again: a later bring-up that fell short does not undo
# this boot's "ready", but a final failure does.
attributes ready attached restored usable
activate
attributes not-ready attached restored usable
run_script && [[ $(<"$status") == "ready" && $(wc -l <"$fixture/sleeps") == 0 ]] ||
  fail "a re-run keeps this boot's ready through a bring-up that fell short"
attributes ready retrying restored usable
! run_script && [[ $(<"$status") == "not-ready" ]] ||
  fail 'a driver loaded again this boot earns ready afresh, from its own attach'
attributes ready attached restored usable
activate
attributes ready attached restored blocked
! run_script && [[ $(<"$status") == "blocked" ]] || fail 'a re-run records a final failure over ready'
pass "a re-run keeps this boot's ready unless Touch ID can no longer match"

# The update that installs the rule finds /dev/sep-bio already there, so a
# pacman hook starts the unit itself rather than waiting for a reboot.
hook=$work/root/usr/share/libalpm/hooks/90-omarchy-mac-touchid.hook
[[ -f $hook ]] || fail 'the Touch ID pacman hook is staged'
grep -Fxq 'Target = usr/lib/udev/rules.d/94-omarchy-mac-touchid.rules' "$hook" &&
  grep -Fxq 'Operation = Install' "$hook" && grep -Fxq 'Operation = Upgrade' "$hook" &&
  grep -Fxq 'When = PostTransaction' "$hook" && grep -Fxq 'Description = Checking Touch ID...' "$hook" &&
  grep -Fxq "Exec = /usr/bin/sh -c 'systemd-detect-virt --quiet --chroot || ! systemd-notify --booted || { systemctl --quiet start omarchy-mac-touchid-status.service; systemctl --quiet start omarchy-mac-touchid-activate.service; true; }'" "$hook" ||
  fail 'the hook records the status, then activates, after the transaction that installs or updates the rule, and never fails it'
# Run as pacman runs it, booted: the status first, the activation even when the
# status fails, and the transaction never fails.
hook_command=$(sed -n "s|^Exec = /usr/bin/sh -c '\(.*\)'$|\1|p" "$hook")
mkdir -p "$fixture/hookbin"
printf '#!/bin/sh\nexit 1\n' >"$fixture/hookbin/systemd-detect-virt"
printf '#!/bin/sh\nexit 0\n' >"$fixture/hookbin/systemd-notify"
printf '#!/bin/sh\necho "$@" >>"%s"\nexit 1\n' "$fixture/hookcalls" >"$fixture/hookbin/systemctl"
chmod +x "$fixture/hookbin/"*
: >"$fixture/hookcalls"
PATH="$fixture/hookbin:$PATH" sh -c "$hook_command" &&
  [[ $(<"$fixture/hookcalls") == $'--quiet start omarchy-mac-touchid-status.service\n--quiet start omarchy-mac-touchid-activate.service' ]] ||
  fail 'the hook starts the status, then the activation, and never fails' "$(<"$fixture/hookcalls")"
target=$(sed -n 's/^Target = //p' "$hook")
[[ -f $work/root/$target ]] || fail "the hook's target is the staged rule" "$target"
pass 'an install or update activates Touch ID in the same session'

if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --no-style "$rule" >/dev/null || fail 'udevadm accepts the rule'
  pass 'udevadm accepts the Touch ID rule'
fi

# fprintd resolves libfprint-git's allowance for /dev/sep-bio when it starts, so
# the drop-in orders it after a unit that waits for the node, and adds no allowance.
dropin=$work/root/usr/lib/systemd/system/fprintd.service.d/50-omarchy-mac-touchid.conf
wait_unit=$work/root/usr/lib/systemd/system/omarchy-mac-touchid-wait.service
[[ -f $dropin && -f $wait_unit ]] || fail 'the fprintd drop-in and the wait unit are staged'
grep -Fxq 'Wants=omarchy-mac-touchid-wait.service' "$dropin" &&
  grep -Fxq 'After=omarchy-mac-touchid-load.service omarchy-mac-touchid-wait.service omarchy-mac-touchid-activate.service' "$dropin" ||
  fail 'fprintd starts after the wait and the activation'
! grep -qE '^(DeviceAllow|DevicePolicy|ExecStartPre)=' "$dropin" ||
  fail "the drop-in leaves fprintd's devices to libfprint-git, which owns the allowance"
grep -Fxq 'After=omarchy-mac-touchid-load.service' "$wait_unit" ||
  fail "the wait follows the boot-time load, so it never looks before the driver has a device"
grep -Fxq 'Type=oneshot' "$wait_unit" && grep -Fxq 'TimeoutStartSec=20s' "$wait_unit" &&
  ! grep -q '^RemainAfterExit=' "$wait_unit" && ! grep -q '^\[Install\]' "$wait_unit" ||
  fail 'the wait runs again before each fprintd start, bounded, and needs no enabling'
wait_command=$(sed -n "s|^ExecStart=/usr/bin/sh -c '\(.*\)'$|\1|p" "$wait_unit")
wait_command=${wait_command//\/dev\/sep-bio/$fixture/sep-bio}
wait_command=${wait_command//\/sys\/bus\/platform\/drivers\/apple_sep/$fixture/wait_sep}
waits() {
  : >"$fixture/sleeps"
  PATH="$fixture/bin:$PATH" sh -c "$wait_command"
  wc -l <"$fixture/sleeps"
}
mkdir -p "$fixture/wait_sep"
rm -f "$fixture/sep-bio"
[[ $(waits) == 0 ]] || fail 'without a Secure Enclave device, fprintd starts at once, so a USB reader is not held up'
mkdir -p "$fixture/wait_sep/396400000.sep"
touch "$fixture/sep-bio"
[[ $(waits) == 0 ]] || fail 'with the node already there, fprintd starts at once'
rm "$fixture/sep-bio"
[[ $(waits) == 150 ]] || fail 'with a device but no node, fprintd waits at most 15 s, then starts anyway'
pass 'fprintd waits for Touch ID only on a Mac whose Secure Enclave driver has a device'

# Verified inside the staged root, whose stub commands stand in for the
# runtime's platform check, so the result never depends on the host.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon sh; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  for name in omarchy-mac-touchid-activate omarchy-mac-touchid-wait; do
    systemd-analyze --root="$work/root" verify --man=no "/usr/lib/systemd/system/$name.service" 2>"$work/verify" ||
      fail "systemd accepts $name" "$(cat "$work/verify")"
  done
  # Arch's fprintd.service lines that matter here: no DevicePolicy, four allowances.
  printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/lib/fprintd"
  chmod +x "$work/root/usr/lib/fprintd"
  printf '[Unit]\nDescription=Fingerprint Authentication Daemon\n\n[Service]\nExecStart=/usr/lib/fprintd\nDeviceAllow=char-usb_device rw\nDeviceAllow=char-spi rw\nDeviceAllow=char-hidraw rw\nDeviceAllow=/dev/cros_fp rw\n' \
    >"$work/root/usr/lib/systemd/system/fprintd.service"
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/fprintd.service 2>"$work/verify-fprintd" ||
    fail 'systemd accepts fprintd with the drop-in' "$(cat "$work/verify-fprintd")"
  pass 'systemd accepts the Touch ID units and fprintd with the drop-in'
fi
