#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# omarchy-mac names Touch ID in the platform root (fingerprint-readers), and
# the runtime's omarchy-hw-fingerprint must find it there: a copy of the
# command reads the staged package, its sysfs path moved under a fixture.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$MAC/install" "$tmp/pkg" >/dev/null
mkdir -p "$tmp/platform" "$tmp/bin" "$tmp/usb"
sed "s|^/sys/|$tmp/sys/|" "$tmp/pkg/usr/share/omarchy-platform/fingerprint-readers" >"$tmp/platform/fingerprint-readers"
grep -q "^$tmp/sys/" "$tmp/platform/fingerprint-readers" || fail "the staged file names a sysfs reader"
platform_root_copy "$ROOT/bin/omarchy-hw-fingerprint" "$tmp/bin/omarchy-hw-fingerprint" "$tmp/platform"

touch_id() {
  mkdir -p "$tmp/sys/bus/platform/drivers/apple_sep/396400000.sep/diag"
  printf '%s\n' "$1" >"$tmp/sys/bus/platform/drivers/apple_sep/396400000.sep/diag/touchid"
}
detects() {
  OMARCHY_USB_DEVICES_PATH="$tmp/usb" "$tmp/bin/omarchy-hw-fingerprint"
}

detects && fail "a Mac whose kernel has no Secure Enclave driver has no reader"
touch_id absent
detects && fail "a Mac whose sensor is not bound has no reader"
touch_id ready
detects || fail "a Mac whose Secure Enclave reports Touch ID ready has a reader"
pass "the runtime finds Touch ID where omarchy-mac names it, only once it is ready"
