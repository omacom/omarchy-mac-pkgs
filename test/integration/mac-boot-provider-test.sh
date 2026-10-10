#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stage"
grep -Fxq omarchy-mac-boot "$ROOT/install/omarchy-$(runtime_platform aarch64-apple).packages" || fail "Apple fresh-install inputs carry the boot package"
pass "Apple installs carry the boot package their lifecycles dispatch to"
bash "$BOOT/install" "$work/stage"
# Owner provisioning and factory reset are upstream's scripts, which run only
# as root: they only parse.
bash -n "$ROOT/bin/omarchy-provision-owner"
bash -n "$ROOT/bin/omarchy-system-factory-reset"
pass "owner provisioning parses, and the boot package ships every operation it dispatches"

# Owner provisioning and factory reset reach the Mac's boot chain only through
# omarchy-lifecycle-dispatch; the boot package owns the files below.
# Factory reset has no Apple step of its own left either, the Mac's first-boot
# state included.
patterns=(/boot/omarchy encrypt.state rd.luks.key /etc/default/grub omarchy-mac-boot omarchy-mac/boot update-grub)
for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  [[ $entry != omarchy-system-factory-reset ]] || patterns+=(omarchy-hw-aarch64-apple omarchy-hw-apple-silicon mac-first-boot efi/omarchy)
  for pattern in "${patterns[@]}"; do
    ! grep -Fq -- "$pattern" "$ROOT/bin/$entry" ||
      fail "$entry leaves $pattern to the boot package" "$(grep -Fn -- "$pattern" "$ROOT/bin/$entry")"
  done
done
for operation in provision-prepare provision-commit provision-verify reset-prepare reset-verify reset-commit reset-rollback luks-slots; do
  [[ -x $work/stage/usr/lib/omarchy/mac-boot/$operation ]] || fail "omarchy-mac-boot ships $operation"
done
dispatched=$(grep -o 'omarchy-lifecycle-dispatch" \(--resolve \)\?[a-z-]*' "$ROOT/bin/omarchy-provision-owner" | awk '{ print $NF }' | sort -u)
[[ -n $dispatched ]] || fail "omarchy-provision-owner dispatches its boot steps"
for operation in $dispatched; do
  [[ -x $work/stage/usr/lib/omarchy/mac-boot/$operation ]] || fail "omarchy-mac-boot ships $operation, which owner provisioning dispatches"
done
pass "owner provisioning and factory reset handle Apple boot files only through the boot package's dispatch entrypoints"
[[ ! -e $work/stage/boot ]] || fail "staging does not change boot files"
while IFS= read -r -d '' file; do
  shipped=$BOOT/files/${file#"$work/stage/"}
  [[ -e $shipped || -L $shipped ]] || fail "staged ${file#"$work/stage"} is a shipped package file"
done < <(find "$work/stage/etc" \( -type f -o -type l \) -print0)
pass "boot package staging writes only its shipped configuration outside vendor paths"
