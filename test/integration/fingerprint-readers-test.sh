#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# omarchy-mac names Touch ID in the platform root (fingerprint-readers) by the
# status its activation records, and the runtime's omarchy-hw-fingerprint must
# find it there: the staged script writes the status from a fixture sysfs.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$MAC/install" "$tmp/pkg" >/dev/null
mkdir -p "$tmp/platform" "$tmp/bin" "$tmp/usb" "$tmp/stub"
sed "s|^/run/|$tmp/run/|" "$tmp/pkg/usr/share/omarchy-platform/fingerprint-readers" >"$tmp/platform/fingerprint-readers"
grep -q "^$tmp/run/omarchy-mac/touchid ready$" "$tmp/platform/fingerprint-readers" ||
  fail "the staged file names the status the activation records"
platform_root_copy "$ROOT/bin/omarchy-hw-fingerprint" "$tmp/bin/omarchy-hw-fingerprint" "$tmp/platform"
printf '#!/bin/sh\nexit 0\n' >"$tmp/stub/sleep"
printf '#!/bin/sh\nexit 0\n' >"$tmp/stub/omarchy-hw-apple-silicon"
chmod +x "$tmp/stub/sleep" "$tmp/stub/omarchy-hw-apple-silicon"
touch "$tmp/sep-bio"

# touchid, sensor_attach, restore and matching, as the Secure Enclave driver
# reports them on a fresh boot, so no earlier status carries over.
touch_id() {
  local diag=$tmp/sys/apple_sep/396400000.sep/diag
  mkdir -p "$diag"
  rm -rf "$tmp/run"
  printf '%s\n' "$1" >"$diag/touchid"
  printf '%s\n' "$2" >"$diag/sensor_attach"
  printf '%s\n' "$3" >"$diag/restore"
  printf '%s\n' "$4" >"$diag/matching"
  PATH="$tmp/stub:$PATH" OMARCHY_MAC_TOUCHID_NODE=$tmp/sep-bio OMARCHY_MAC_TOUCHID_DRIVER=$tmp/sys/apple_sep \
    OMARCHY_MAC_TOUCHID_STATUS=$tmp/run/omarchy-mac/touchid OMARCHY_MAC_TOUCHID_ATTEMPTS=1 \
    "$tmp/pkg/usr/lib/omarchy-mac/touchid-activate" 2>/dev/null || true
}
detects() {
  OMARCHY_USB_DEVICES_PATH="$tmp/usb" "$tmp/bin/omarchy-hw-fingerprint"
}

detects && fail "a Mac whose Touch ID was never activated has no reader"
touch_id ready attached restored usable
detects || fail "a Mac whose Touch ID can enrol and match has a reader"
touch_id ready attached restored legacy
detects || fail "restored historical enrollments can attempt a real match"
touch_id ready attached empty legacy
detects || fail "a historical bag with an empty restore can enroll its first print"
touch_id ready attached empty blocked
detects && fail "a storage refusal still blocks the empty reader"
touch_id ready attached unproven legacy
detects && fail "historical provenance cannot bypass a failed restore"
touch_id ready attached empty unverified
detects || fail "a Mac with nothing enrolled yet, behind a guard that has refused nothing, has a reader"
pass "the runtime finds Touch ID where omarchy-mac names it, once it can enrol and match"

touch_id ready not-ready unknown usable
detects && fail "a sensor that never came online is no reader"
touch_id ready attached unproven usable
detects && fail "fingerprints whose restore is unproven are no reader"
touch_id ready attached restored blocked
detects && fail "a Mac whose matches cannot save their state is no reader"
pass "a Touch ID that reads ready but cannot enrol or match is no reader"

# Before the owner agrees, the boot status names a Touch ID that can be turned
# on, so the invitation can ask; one that can't be set up is no reader.
for status in available unsupported:board; do
  rm -rf "$tmp/run"
  mkdir -p "$tmp/run/omarchy-mac"
  printf '%s\n' "$status" >"$tmp/run/omarchy-mac/touchid"
  if [[ $status == "available" ]]; then
    detects || fail "a Touch ID the owner can turn on is a reader"
  else
    detects && fail "a Touch ID that can't be set up is no reader"
  fi
done
pass "the runtime finds a Touch ID the owner can turn on, and not one that can't be set up"

# A Touch ID that isn't ready never hides a USB reader beside it.
mkdir -p "$tmp/usb/1-0"
printf '27c6\n' >"$tmp/usb/1-0/idVendor"
printf '1234\n' >"$tmp/usb/1-0/idProduct"
detects || fail "a USB reader is found beside a Touch ID that is not ready"
pass "a Touch ID that is not ready leaves a USB reader to be found"

# Follow the actual setup -> --resolve -> privileged dispatch -> owner hook
# contract. Restrict all privilege and device access to the staged root.
helpers=$tmp/pkg/usr/lib/omarchy-mac
owner=$tmp/pkg/usr/lib/omarchy/mac/enable-fingerprint
sed -e "s|/usr/lib/omarchy-mac/|$helpers/|g" -e "s|/etc/omarchy-mac/|$tmp/pkg/etc/omarchy-mac/|g" \
  -e "s|/run/omarchy-mac/|$tmp/run/omarchy-mac/|g" "$MAC/entrypoints/enable-fingerprint" >"$owner"
sed -i -e "s|:-/usr/lib/omarchy-mac|:-$helpers|g" -e "s|:-/sys/module/apple_sep|:-$tmp/module|g" \
  -e "s|:-/sys/bus/platform/drivers/apple_sep|:-$tmp/sys/apple_sep|g" -e "s|:-/dev/sep-bio|:-$tmp/sep-bio|g" \
  -e "s|:-/etc/omarchy-mac/touchid-on|:-$tmp/pkg/etc/omarchy-mac/touchid-on|g" \
  -e "s|:-/run/omarchy-mac/touchid|:-$tmp/run/omarchy-mac/touchid|g" "$helpers/touchid-kernel-ready"
sed -i "s|:-/proc/device-tree|:-$tmp/tree|g" "$helpers/touchid-board.sh"
sed -e "s|^fixed_path=.*|fixed_path=$tmp/stub:/usr/bin|" -e "s|^  root=\"\"|  root=$tmp/pkg|" \
  "$ROOT/bin/omarchy-lifecycle-dispatch" >"$tmp/bin/omarchy-lifecycle-dispatch"
printf '#!/bin/bash\necho %s\n' "$(runtime_platform aarch64-apple)" >"$tmp/bin/omarchy-hw-platform"
printf '#!/bin/bash\nexit 1\n' >"$tmp/stub/omarchy-pkg-missing"
cat >"$tmp/stub/sudo" <<'SH'
#!/bin/bash
case "$*" in
  "-n true") exit 0 ;;
  "omarchy-lifecycle-dispatch enable-fingerprint"|fprintd-enroll*) exec "$@" ;;
  *) exit 1 ;;
esac
SH
for command in busctl fprintd-enroll; do
  printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 1\n' "$command" "$tmp/probes" >"$tmp/stub/$command"
done
chmod +x "$tmp/bin/"* "$tmp/stub/"*
mkdir -p "$tmp/module" "$tmp/tree"
printf 'apple,j293\0apple,t8103\0' >"$tmp/tree/compatible"
echo unsupported:m1-family >"$tmp/run/omarchy-mac/touchid"
setup() {
  OMARCHY_USB_DEVICES_PATH="$tmp/usb" OMARCHY_LIFECYCLE_ROOT="$tmp/pkg" PATH="$tmp/bin:$tmp/stub:/usr/bin" \
    "$ROOT/bin/omarchy-setup-security-fingerprint" </dev/null >"$tmp/setup-output" 2>&1
}
! setup && grep -q 'nothing was enrolled' "$tmp/setup-output" && [[ ! -e $tmp/probes ]] ||
  fail "the actual dispatcher stops setup before fprintd opens an unproven SEP alongside USB" "$(cat "$tmp/setup-output")"
rm -rf "$tmp/module" "$tmp/sep-bio"
! setup && grep -q GetDefaultDevice "$tmp/probes" && grep -q fprintd-enroll "$tmp/probes" ||
  fail "the same setup reaches USB enumeration and enrollment with SEP absent" "$(cat "$tmp/setup-output")"
pass "fingerprint setup honors the owner hook before D-Bus or enrollment, including with a USB reader attached"
