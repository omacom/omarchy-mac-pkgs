#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# An M1-family Mac records only zeros until its Secure Enclave boots, and the
# installed kernel's module has no alias, so the package boots it read-only at
# every boot, before the greeter, where the owner has not turned Touch ID on.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
unit=$units/omarchy-mac-sep-load.service
helper=$work/root/usr/lib/omarchy-mac/sep-for-microphone
[[ -f $unit && -x $helper && -L $units/multi-user.target.wants/omarchy-mac-sep-load.service &&
  $(readlink "$units/multi-user.target.wants/omarchy-mac-sep-load.service") == "../omarchy-mac-sep-load.service" ]] ||
  fail 'the unit and its helper are staged, and the unit is pulled in at boot without enabling'
grep -Fxq 'ExecStart=/usr/bin/modprobe apple-sep xart_writes=0 provision_keybag=0' "$unit" ||
  fail 'the driver loads read-only: it never writes the xART store shared with macOS and makes no keybag'
! grep -Eq 'xart_writes=1|provision_keybag=1' "$unit" "$helper" || fail 'nothing here turns the writes or the provisioning on'
grep -Fxq 'ConditionPathExists=!/etc/omarchy-mac/touchid-on' "$unit" ||
  fail "once the owner has turned Touch ID on, its own load owns the driver"
grep -Fxq 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$unit" && grep -Fxq 'ExecCondition=/usr/lib/omarchy-mac/sep-for-microphone' "$unit" ||
  fail 'the unit runs only on an Apple Silicon Mac whose microphone needs the enclave'
grep -Fxq 'ExecStartPre=/usr/bin/udevadm wait --timeout=20 /dev/disk/by-partlabel/iBootSystemContainer' "$unit" ||
  fail "the driver loads after the iBoot System Container's link it opens as it probes"
! grep -Eq '^(Wants|Requires|BindsTo|After)=.*\.device' "$unit" ||
  fail 'the load waits for the link only once its conditions hold: a device dependency holds up every boot'
grep -Fxq 'Before=display-manager.service' "$unit" && grep -Fxq 'Type=oneshot' "$unit" && grep -Fxq 'TimeoutStartSec=30s' "$unit" ||
  fail "the enclave is up before the session's first capture, within a bounded time"
! grep -q '^\[Install\]' "$unit" || fail 'the unit needs no enabling: the wants link pulls it in'
pass 'the package boots the Secure Enclave read-only at boot, only while Touch ID is off'

# The helper reads only the device tree: an M1-family Mac whose tree enables
# its enclave needs it; later Macs, a tree that disables the node, a Mac
# without one and another platform do not.
fixture=$work/fixture
mkdir -p "$fixture/bin"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$fixture/bin/omarchy-hw-platform"
stub_apple_predicate "$fixture/bin"
chmod +x "$fixture/bin/"*
tree() {
  local root=$1 status=${3:-okay}
  rm -rf "$root"
  mkdir -p "$root/soc/sep@242400000"
  printf '%s\0' $2 >"$root/compatible"
  printf 'apple,sep\0' >"$root/soc/sep@242400000/compatible"
  if [[ $status != "none" ]]; then
    printf '%s\0' "$status" >"$root/soc/sep@242400000/status"
  fi
}
needs() {
  PATH="$fixture/bin:$PATH" OMARCHY_MAC_SEP_TREE=$fixture/tree "$ROOT/lib/sep-for-microphone"
}
for board in 'apple,j313 apple,t8103 apple,arm-platform' 'apple,j314s apple,t6000 apple,arm-platform' 'apple,j316c apple,t6001 apple,arm-platform'; do
  tree "$fixture/tree" "$board"
  needs || fail 'an M1-family Mac with its enclave enabled needs it' "$board"
  tree "$fixture/tree" "$board" none
  needs || fail 'a node without a status is enabled' "$board"
  tree "$fixture/tree" "$board" disabled
  ! needs || fail 'a tree that disables the enclave never loads its driver' "$board"
done
for board in 'apple,j413 apple,t8112 apple,arm-platform' 'apple,j414s apple,t6020 apple,arm-platform' 'apple,j613 apple,t8122 apple,arm-platform'; do
  tree "$fixture/tree" "$board"
  ! needs || fail 'a later Mac records without the enclave, so its driver stays unloaded' "$board"
done
tree "$fixture/tree" 'apple,j313 apple,t8103 apple,arm-platform'
rm -r "$fixture/tree/soc/sep@242400000"
! needs || fail 'a tree without an enclave node loads nothing'
tree "$fixture/tree" 'apple,j313 apple,t8103 apple,arm-platform'
! PLATFORM=x86_64 needs || fail 'the platform decides first'
status=0
PATH="$fixture/bin:$PATH" OMARCHY_MAC_SEP_TREE=$fixture/missing "$ROOT/lib/sep-for-microphone" || status=$?
(( status == 1 )) || fail 'without a device tree the unit is skipped, not failed' "$status"
pass 'only an M1-family Mac whose device tree enables its enclave boots it'

# Verified inside the staged root, whose stub commands stand in for the
# runtime's platform check, so the result never depends on the host.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon modprobe udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/omarchy-mac-sep-load.service 2>"$work/verify" ||
    fail 'systemd accepts the unit' "$(cat "$work/verify")"
  pass 'systemd accepts the Secure Enclave load unit'
fi
if command -v systemd-analyze >/dev/null && systemd-analyze condition --help >/dev/null 2>&1; then
  agreed=$work/condition/touchid-on
  mkdir -p "$work/condition"
  condition=$(grep '^ConditionPathExists=' "$unit")
  systemd-analyze condition "${condition//\/etc\/omarchy-mac\/touchid-on/$agreed}" >/dev/null 2>&1 ||
    fail 'a Mac whose owner has not turned Touch ID on runs the unit'
  touch "$agreed"
  ! systemd-analyze condition "${condition//\/etc\/omarchy-mac\/touchid-on/$agreed}" >/dev/null 2>&1 ||
    fail "a Mac whose owner turned Touch ID on leaves the driver to its own load"
  pass 'the unit yields to the Touch ID load once the owner has agreed'
fi
