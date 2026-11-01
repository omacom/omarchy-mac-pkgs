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
