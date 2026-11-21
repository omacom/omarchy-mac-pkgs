#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# The runtime's fingerprint setup and removal edit sudo's and polkit's stacks
# around omarchy-mac's Touch ID re-arm block: each keeps the other's lines, and
# turning Touch ID off leaves what the runtime alone would.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$MAC/install" "$tmp/pkg" >/dev/null
mkdir -p "$tmp/pam.d" "$tmp/alone" "$tmp/stub" "$tmp/etc"
printf '#!/bin/sh\nexit 0\n' >"$tmp/stub/omarchy-hw-apple-silicon"
printf '#!/bin/bash\nexec "$@"\n' >"$tmp/stub/sudo"
chmod +x "$tmp/stub/"*
touch "$tmp/pam_aurora_touchid.so"
printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\nsession\t\tinclude\t\tsystem-auth\n' >"$tmp/pam.d/sudo"
cp "$tmp/pam.d/sudo" "$tmp/alone/sudo"

sync() {
  PATH="$tmp/stub:$PATH" OMARCHY_MAC_TOUCHID_AGREED=$tmp/etc/touchid-on OMARCHY_MAC_PAMD=$tmp/pam.d \
    OMARCHY_MAC_TOUCHID_PAM_MODULE=$tmp/pam_aurora_touchid.so OMARCHY_MAC_TOUCHID_PAM_LOCK=$tmp/run/touchid-pam.lock \
    "$tmp/pkg/usr/lib/omarchy-mac/touchid-pam"
}
# The runtime's own PAM edits, pointed at a fixture directory.
runtime() {
  local script=$1 function=$2 directory=$3
  PATH="$tmp/stub:$PATH" bash -c "$(sed -n "/^$function() {/,/^}/p" "$ROOT/bin/$script" | sed "s|/etc/pam.d/|$directory/|g"); $function" >/dev/null
}
block() {
  grep -A2 -E '^auth[[:space:]]+include[[:space:]]+system-auth' "$1" | tail -n 2
}
without_block() {
  grep -Fxv -e '-auth      optional                    pam_aurora_touchid.so' \
    -e '# omarchy-mac: a password here re-arms Touch ID; turning Touch ID off removes this' "$1"
}

# enable-fingerprint runs before the runtime writes its fingerprint lines, and
# the boot sync reaches the polkit stack the runtime creates after enrolling.
touch "$tmp/etc/touchid-on"
sync
runtime omarchy-setup-security-fingerprint setup_pam_config "$tmp/pam.d"
sync
runtime omarchy-setup-security-fingerprint setup_pam_config "$tmp/alone"
for service in sudo polkit-1; do
  [[ $(block "$tmp/pam.d/$service") == *pam_aurora_touchid.so ]] ||
    fail "$service carries the re-arm straight after its system-auth include" "$(<"$tmp/pam.d/$service")"
  diff <(without_block "$tmp/pam.d/$service") "$tmp/alone/$service" >/dev/null ||
    fail "$service keeps every line the runtime's setup wrote" "$(<"$tmp/pam.d/$service")"
done
grep -n pam_fprintd "$tmp/pam.d/sudo" | cut -d: -f1 | {
  read -r fingerprint
  (( fingerprint < $(grep -n pam_aurora_touchid "$tmp/pam.d/sudo" | cut -d: -f1) ))
} || fail 'a fingerprint still ends sudo before the re-arm'
pass "the runtime's fingerprint setup and the re-arm block keep each other's lines"

runtime omarchy-remove-security-fingerprint remove_pam_config "$tmp/pam.d"
runtime omarchy-remove-security-fingerprint remove_pam_config "$tmp/alone"
rm "$tmp/etc/touchid-on"
sync
for service in sudo polkit-1; do
  cmp -s "$tmp/pam.d/$service" "$tmp/alone/$service" ||
    fail "removing the fingerprint and turning Touch ID off leave $service as the runtime alone would" "$(<"$tmp/pam.d/$service")"
done
pass "the runtime's fingerprint removal and turning Touch ID off leave what the runtime alone would"
