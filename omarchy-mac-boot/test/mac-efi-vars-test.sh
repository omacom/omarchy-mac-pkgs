#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# At shutdown, the EFI variables U-Boot kept in RAM (VarToFile) are written to
# the variable file it names (RTStorageVolatile) on the ESP.
FILES=$ROOT/files
SCRIPT=$FILES/usr/lib/omarchy/mac-boot/efi-vars-save
UNIT=$FILES/usr/lib/systemd/system/omarchy-mac-efi-vars.service
WANTS=$FILES/usr/lib/systemd/system/multi-user.target.wants/omarchy-mac-efi-vars.service
GUID=b2ac5fc9-92b7-4acd-aeac-11e818c3130c

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A U-Boot variable store: reserved u64, "UbEfiVa\x01", length u32 LE, crc32,
# then the variables (here a marker string standing in for them).
store() {
  local body=$1 length
  length=$((24 + ${#body}))
  printf '\0\0\0\0\0\0\0\0UbEfiVa\x01'
  printf '%b' "\\x$(printf %02x $((length & 255)))\\x$(printf %02x $((length >> 8 & 255)))\\0\\0"
  printf '\x11\x22\x33\x44%s' "$body"
}

# efivarfs: 4 attribute bytes (NV|BS|RT here), then the value.
efivar() { { printf '\x07\0\0\0'; cat; } >"$tmp/efivars/$1-$GUID"; }

new_mac() {
  rm -rf "$tmp/efivars" "$tmp/esp" "$tmp/bin" "$tmp/out" "$tmp/err"
  mkdir -p "$tmp/efivars" "$tmp/esp" "$tmp/bin"
  printf 'ubootefi.var\0' | efivar RTStorageVolatile
  store "boot-menu-request" | efivar VarToFile
  store "boot-entries" >"$tmp/esp/ubootefi.var"
  printf '#!/bin/bash\n[[ -d %q ]] && echo %q\n' "$tmp/esp" "$tmp/esp" >"$tmp/bin/omarchy-mac-esp"
  chmod +x "$tmp/bin/omarchy-mac-esp"
}

save() { OMARCHY_EFIVARS=$tmp/efivars PATH="$tmp/bin:$PATH" bash "$SCRIPT" >"$tmp/out" 2>"$tmp/err"; }
saved() { cmp -s <(tail -c +5 "$tmp/efivars/VarToFile-$GUID") "$tmp/esp/ubootefi.var"; }
untouched() { cmp -s <(store "boot-entries") "$tmp/esp/ubootefi.var" && [[ ! -e $tmp/esp/ubootefi.var.new ]]; }

new_mac
save || fail "a changed store is saved: $(cat "$tmp/err")"
saved || fail "the ESP file holds VarToFile without its attributes"
[[ $(stat -c %a "$tmp/esp/ubootefi.var") == 600 && ! -e $tmp/esp/ubootefi.var.new ]] || fail "the file is replaced whole, root-only"
grep -Fqx "Saved runtime EFI variables to $tmp/esp/ubootefi.var" "$tmp/out" || fail "the save is logged: $(cat "$tmp/out")"
pass "runtime EFI variables are saved to U-Boot's variable file"

touch -d @1 "$tmp/esp/ubootefi.var"
save && [[ ! -s $tmp/out && $(stat -c %Y "$tmp/esp/ubootefi.var") == 1 ]] || fail "an unchanged store is not rewritten"
pass "an unchanged store is left alone"

new_mac
printf '/ubootefi.var\0' | efivar RTStorageVolatile
save && saved || fail "a name from the ESP root is accepted: $(cat "$tmp/err")"
pass "a variable file named from the ESP root is saved"

new_mac
rm "$tmp/efivars/RTStorageVolatile-$GUID" "$tmp/efivars/VarToFile-$GUID"
save && untouched && [[ ! -s $tmp/out && ! -s $tmp/err ]] || fail "firmware without U-Boot's runtime store is skipped"
pass "nothing happens where U-Boot names no variable file"

for case in no-store dotdot nested-dotdot empty-name bad-magic short-length no-esp linked-target; do
  new_mac
  case $case in
    no-store) rm "$tmp/efivars/VarToFile-$GUID" ;;
    dotdot) printf '../ubootefi.var\0' | efivar RTStorageVolatile ;;
    nested-dotdot) printf 'EFI/../../x\0' | efivar RTStorageVolatile ;;
    empty-name) printf '\0' | efivar RTStorageVolatile ;;
    bad-magic) { printf '\0\0\0\0\0\0\0\0NotUBoot'; head -c 16 /dev/zero; } | efivar VarToFile ;;
    short-length) { store "boot-menu-request"; printf 'trailing'; } | efivar VarToFile ;;
    no-esp) rm -rf "$tmp/esp" ;;
    linked-target) mv "$tmp/esp/ubootefi.var" "$tmp/real.var"; ln -s "$tmp/real.var" "$tmp/esp/ubootefi.var" ;;
  esac
  ! save || fail "$case: the save is refused"
  grep -Fq 'runtime EFI variable changes are not saved' "$tmp/err" || fail "$case: the refusal says what is lost: $(cat "$tmp/err")"
  case $case in
    no-esp) ;;
    linked-target) cmp -s <(store "boot-entries") "$tmp/real.var" || fail "linked-target: the link's target is not written" ;;
    *) untouched || fail "$case: the ESP file is untouched" ;;
  esac
done
pass "an unusable name, store, ESP or target is refused without writing"

# The unit: runs the script as it stops, ordered so efivarfs and the ESP are
# still mounted, and pulled in statically.
grep -Fqx 'ExecStop=/usr/lib/omarchy/mac-boot/efi-vars-save' "$UNIT" || fail "the unit saves as it stops"
grep -Fqx 'RemainAfterExit=yes' "$UNIT" && grep -Fqx 'Type=oneshot' "$UNIT" || fail "the unit stays active until shutdown"
grep -Fqx 'After=sys-firmware-efi-efivars.mount' "$UNIT" || fail "the unit stops before efivarfs is unmounted"
grep -Fqx 'RequiresMountsFor=/boot/efi' "$UNIT" || fail "the unit stops before the ESP is unmounted"
grep -Fqx "ConditionPathExists=/sys/firmware/efi/efivars/RTStorageVolatile-$GUID" "$UNIT" || fail "the unit is skipped without U-Boot's runtime store"
[[ -L $WANTS && $(readlink "$WANTS") == ../omarchy-mac-efi-vars.service && -x $SCRIPT ]] || fail "multi-user.target pulls the unit in"
pass "omarchy-mac-efi-vars.service saves at shutdown on every Mac"
