#!/bin/bash
# omarchy-mac-esp-space and 00-omarchy-mac-esp-space.hook: before a transaction stages firmware or a
# boot image on the ESP, a failed run's leftovers go and a lack of room fails it with nothing changed.
# limine-esp-limit keeps snapshot kernels to what leaves that room.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

space=$ROOT/bin/omarchy-mac-esp-space
limit=$ROOT/files/usr/lib/omarchy/mac-boot/limine-esp-limit
hook=$ROOT/files/usr/share/libalpm/hooks/00-omarchy-mac-esp-space.hook
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
esp=$tmp/esp
mkdir -p "$tmp/bin"

# df reports the ESP as TEST_ESP_SIZE KiB with TEST_ESP_FREE KiB available.
cat >"$tmp/bin/df" <<'SH'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p4 %s 0 %s 0%% %s\n' "$TEST_ESP_SIZE" "$TEST_ESP_FREE" "${@: -1}"
SH
printf '#!/bin/bash\necho "$TEST_ESP_FOUND"\n[[ -n $TEST_ESP_FOUND ]]\n' >"$tmp/bin/omarchy-mac-esp"
cat >"$tmp/bin/omarchy-mac-limine-active" <<'SH'
#!/bin/bash
[[ -n ${TEST_LIMINE:-} ]]
SH
printf '#!/bin/bash\necho linux-aurora\n' >"$tmp/bin/omarchy-mac-kernel"
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" TEST_ESP_SIZE=$((499 << 10)) TEST_ESP_FREE=$((400 << 10)) TEST_ESP_FOUND=$esp

mib() { head -c "$(( $2 << 20 ))" /dev/zero >"$1"; }
fresh_esp() {
  rm -rf "$esp"
  mkdir -p "$esp/asahi" "$esp/vendorfw" "$esp/EFI/Linux" "$esp/EFI/BOOT" "$esp/m1n1"
  : >"$esp/asahi/all_firmware.tar.gz"
  mib "$esp/vendorfw/firmware.cpio" 40
  mib "$esp/EFI/Linux/omarchy_linux-aurora.efi" 20
  mib "$esp/EFI/BOOT/BOOTAA64.EFI" 1
}
run() {
  set +e
  bash "$space" "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
}

grep -Fxq 'When = PreTransaction' "$hook" && grep -Fxq 'AbortOnFail' "$hook" && grep -Fxq 'NeedsTargets' "$hook" &&
  grep -Fxq 'Exec = /usr/bin/omarchy-mac-esp-space --pacman' "$hook" || fail "the hook checks before the transaction and aborts it"
for target in aurora-fwextract asahi-fwextract usr/lib/modules/*/vmlinuz usr/lib/initcpio/* usr/share/limine/BOOTAA64.EFI; do
  grep -Fxq "Target = $target" "$hook" || fail "the hook runs for $target"
done
bash "$ROOT/install" "$tmp/stage"
[[ -x $tmp/stage/usr/bin/omarchy-mac-esp-space && -f $tmp/stage/usr/share/libalpm/hooks/00-omarchy-mac-esp-space.hook &&
  -x $tmp/stage/usr/lib/omarchy/mac-boot/limine-esp-limit ]] || fail "the package ships the command, the hook and the limit helper"
pass "the hook checks the ESP before a firmware, kernel, initramfs or Limine transaction and can abort it"

# Room for a whole new vendorfw beside the live one, plus a tenth and 16 MiB.
fresh_esp
fw=$(du -sk "$esp/vendorfw" | cut -f1)
uki=$(du -sk "$esp/EFI/Linux/omarchy_linux-aurora.efi" | cut -f1)
[[ $(bash "$space" --esp "$esp" --firmware --print-need) == $(( fw + fw / 10 + 16384 )) ]] || fail "the firmware needs its own size again"
[[ $(bash "$space" --esp "$esp" --boot-image --print-need) == $(( uki + uki / 4 + 16384 )) ]] || fail "a boot image needs the largest one's size and a quarter"
[[ $(bash "$space" --esp "$esp" --firmware --boot-image --print-need) == $(( fw + fw / 10 + 16384 )) ]] || fail "steps that free their room in turn need the largest"
mv "$esp/vendorfw" "$esp/elsewhere"
mkdir "$esp/vendorfw"
[[ $(bash "$space" --esp "$esp" --firmware --print-need) == $(( 102400 + 10240 + 16384 )) ]] || fail "missing firmware counts 100 MiB"
[[ $(bash "$space" --esp "$esp" --firmware --boot-image --print-need) == $(( 102400 + uki + uki / 4 + 16384 )) ]] || fail "missing firmware stays on the ESP while the boot image is staged"
rmdir "$esp/vendorfw"
mv "$esp/elsewhere" "$esp/vendorfw"
rm "$esp/asahi/all_firmware.tar.gz"
[[ $(bash "$space" --esp "$esp" --firmware --print-need) == 0 ]] || fail "a Mac without the firmware tarball stages no firmware"
pass "the room needed is the largest staged copy with a margin"

fresh_esp
run --pacman <<<'aurora-fwextract'
(( status == 0 )) || fail "a firmware update with room passes" "$(<"$tmp/err")"
TEST_ESP_FREE=$((50 << 10))
run --pacman <<<'aurora-fwextract'
(( status == 1 )) || fail "a firmware update without room fails"
grep -Fq "has 50 MiB free, and this update needs $(( (fw + fw / 10 + 16384) >> 10 )) MiB there to stage the new vendor firmware" "$tmp/err" &&
  grep -Fq "No package was changed" "$tmp/err" || fail "the lack of room is explained" "$(<"$tmp/err")"
run --pacman <<<'usr/lib/modules/7.3.0-0testedgeC-1-ARCH/vmlinuz'
(( status == 0 )) || fail "a kernel update that fits passes though the firmware would not" "$(<"$tmp/err")"
TEST_ESP_FREE=$((30 << 10))
run --pacman <<<'usr/lib/modules/7.3.0-0testedgeC-1-ARCH/vmlinuz'
(( status == 1 )) && grep -Fq "to stage a new boot image beside the 20 MiB one" "$tmp/err" || fail "a kernel update without room for the UKI fails" "$(<"$tmp/err")"
[[ -s $esp/EFI/Linux/omarchy_linux-aurora.efi && -d $esp/vendorfw ]] || fail "a refused update changes nothing"
pass "a transaction without room for what it stages fails before anything changes"

# A failed run's staging is removed before measuring, so its room counts as free.
fresh_esp
TEST_ESP_FREE=$((400 << 10))
mkdir "$esp/vendorfw.new"
mib "$esp/vendorfw.new/firmware.cpio" 30
: >"$esp/EFI/BOOT/BOOTAA64.EFI.new"
: >"$esp/EFI/Linux/omarchy_linux-aurora.efi.new"
run --pacman --firmware-pending "$tmp/state/firmware-pending" <<<'aurora-fwextract'
(( status == 0 )) || fail "a Mac with leftovers passes" "$(<"$tmp/err")"
[[ -e $tmp/state/firmware-pending ]] || fail "a removed vendorfw.new records the unfinished firmware update"
[[ ! -e $esp/vendorfw.new && ! -e $esp/EFI/BOOT/BOOTAA64.EFI.new && ! -e $esp/EFI/Linux/omarchy_linux-aurora.efi.new ]] ||
  fail "leftover staging stays on the ESP"
grep -Fq "removed $esp/vendorfw.new, left by an update that did not finish" "$tmp/err" || fail "the removal is reported" "$(<"$tmp/err")"
[[ -s $esp/vendorfw/firmware.cpio && -s $esp/EFI/Linux/omarchy_linux-aurora.efi && -s $esp/EFI/BOOT/BOOTAA64.EFI ]] || fail "the live files are kept"
mkdir "$esp/vendorfw.new"
bash "$space" --esp "$esp" --firmware --print-need >/dev/null
[[ -d $esp/vendorfw.new ]] || fail "--print-need removes nothing"
rm -rf "$tmp/state" "$esp/vendorfw.new"
: >"$esp/EFI/Linux/omarchy_linux-aurora.efi.new"
run --boot-image --firmware-pending "$tmp/state/firmware-pending"
[[ ! -e $tmp/state ]] || fail "a removed UKI staging records no firmware update"
pass "a failed run's vendorfw.new, Limine and UKI staging is removed first, and an unfinished firmware update recorded"

# asahi-fwupdate died after removing the live firmware: vendorfw.new is the only copy.
for live in gone emptied; do
  fresh_esp
  rm -rf "$esp/vendorfw" "$tmp/state"
  [[ $live == gone ]] || mkdir "$esp/vendorfw"
  mkdir "$esp/vendorfw.new"
  mib "$esp/vendorfw.new/firmware.cpio" 30
  bash "$space" --esp "$esp" --firmware --print-need >/dev/null
  [[ -s $esp/vendorfw.new/firmware.cpio ]] || fail "--print-need moves nothing"
  run --pacman --firmware-pending "$tmp/state/firmware-pending" <<<'aurora-fwextract'
  (( status == 0 )) && [[ $(stat -c %s "$esp/vendorfw/firmware.cpio") == $(( 30 << 20 )) && ! -e $esp/vendorfw.new && -e $tmp/state/firmware-pending ]] ||
    fail "the only firmware copy takes the place of a live one that is $live, and stays pending" "$(<"$tmp/err")"
done
fresh_esp
rm -rf "$esp/vendorfw"/* "$tmp/state"
mkdir "$esp/vendorfw.new"
: >"$esp/vendorfw.new/firmware.cpio"
run --pacman --firmware-pending "$tmp/state/firmware-pending" <<<'aurora-fwextract'
[[ -d $esp/vendorfw && ! -e $esp/vendorfw.new ]] || fail "an empty staging copy is not firmware"
fresh_esp
rm -rf "$esp/vendorfw"
mkdir "$esp/vendorfw.new"
mib "$esp/vendorfw.new/firmware.cpio" 30
run --pacman --firmware-pending /dev/null/firmware-pending <<<'aurora-fwextract'
(( status == 1 )) && [[ -s $esp/vendorfw.new/firmware.cpio ]] || fail "firmware whose unfinished update cannot be recorded is not touched" "$(<"$tmp/err")"
pass "a vendorfw.new that is the only firmware copy is kept and put in place"

# A missing UKI is sized by its kernel and initramfs, not by the loader left on the ESP.
export OMARCHY_MAC_BOOT_DIR=$tmp/boot
fresh_esp
mkdir "$tmp/boot"
mib "$tmp/boot/vmlinuz-linux-aurora" 33
mib "$tmp/boot/initramfs-linux-aurora.img" 25
rm "$esp/EFI/Linux/omarchy_linux-aurora.efi"
loader=$(du -sk "$esp/EFI/BOOT/BOOTAA64.EFI" | cut -f1)
parts=$(( $(du -sk "$tmp/boot/vmlinuz-linux-aurora" | cut -f1) + $(du -sk "$tmp/boot/initramfs-linux-aurora.img" | cut -f1) ))
[[ $(TEST_LIMINE=1 bash "$space" --esp "$esp" --boot-image --print-need) == $(( parts + parts / 4 + 16384 )) ]] || fail "a missing UKI needs its kernel's and initramfs's size"
rm "$tmp/boot/initramfs-linux-aurora.img"
[[ $(TEST_LIMINE=1 bash "$space" --esp "$esp" --boot-image --print-need) == $(( 65536 + 65536 / 4 + 16384 )) ]] || fail "a missing UKI that cannot be measured counts 64 MiB"
[[ $(bash "$space" --esp "$esp" --boot-image --print-need) == $(( loader + loader / 4 + 16384 )) ]] || fail "a GRUB Mac has no UKI to size"
TEST_ESP_FREE=$((50 << 10)) TEST_LIMINE=1 run --boot-image
(( status == 1 )) && grep -Fq "in place of the missing EFI/Linux/omarchy_linux-aurora.efi" "$tmp/err" && ! grep -Fq "No package was changed" "$tmp/err" ||
  fail "a missing UKI without room is refused" "$(<"$tmp/err")"
pass "a missing UKI is sized by what it is built from"

# A Mac from before limine-esp-limit, its snapshots filling a 499 MiB ESP to the old 85%: its first
# update with the hook sets the limit, has limine-snapper-sync drop the oldest entries, and goes on.
cat >"$tmp/bin/df" <<'SH'
#!/bin/bash
free=$TEST_ESP_FREE
[[ -z ${TEST_ESP_USED_FILE:-} ]] || free=$(( TEST_ESP_SIZE - $(<"$TEST_ESP_USED_FILE") ))
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p4 %s 0 %s 0%% %s\n' "$TEST_ESP_SIZE" "$free" "${@: -1}"
SH
# limine-snapper-sync's auto-prune: the oldest snapshot kernel goes while the ESP is over the limit.
cat >"$tmp/bin/limine-snapper-sync" <<'SH'
#!/bin/bash
echo sync >>"$TEST_SYNCS"
[[ -z ${TEST_SYNC_FAILS:-} ]] || exit 1
grep -Fxq MAX_SNAPSHOT_ENTRIES=auto "$OMARCHY_LIMINE_DEFAULT" || exit 0
percent=$(sed -n 's/^LIMIT_USAGE_PERCENT=//p' "$OMARCHY_LIMINE_DEFAULT")
for image in "$TEST_HISTORY"/*; do
  used=$(<"$TEST_ESP_USED_FILE")
  (( used * 100 > percent * TEST_ESP_SIZE )) || break
  echo $(( used - $(du -k "$image" | cut -f1) )) >"$TEST_ESP_USED_FILE"
  rm "$image"
done
SH
chmod +x "$tmp/bin"/*
echo 0123456789abcdef >"$tmp/machine-id"
history=$esp/0123456789abcdef/limine_history
export TEST_SYNCS=$tmp/syncs TEST_HISTORY=$history OMARCHY_LIMINE_DEFAULT=$tmp/limine OMARCHY_LIMINE_ESP_LIMIT=$limit OMARCHY_MACHINE_ID=$tmp/machine-id
near_limit() {
  local snapshot
  fresh_esp
  mib "$esp/EFI/Linux/omarchy_linux-aurora.efi" 64
  mkdir -p "$history"
  for (( snapshot = 1; snapshot <= ${1:-3}; snapshot++ )); do mib "$history/omarchy_linux-aurora.efi_sha256_$snapshot" 64; done
  printf 'ESP_PATH="/boot/efi"\n' >"$tmp/limine"
  echo $(( TEST_ESP_SIZE * 85 / 100 )) >"$tmp/used"
  : >"$tmp/syncs"
}
snapshots() { ls "$history" 2>/dev/null | sed 's/.*_/uki_/' | tr '\n' ' '; }
kernel_update() { PATH="$tmp/bin:$ROOT/bin:$PATH" TEST_LIMINE=1 TEST_ESP_USED_FILE=$tmp/used run --pacman <<<'usr/lib/modules/7.3.0-1-1-ARCH/vmlinuz'; }
near_limit
kernel_update
(( status == 0 )) || fail "the first kernel update on a Mac at the old 85% limit goes on" "$(<"$tmp/err")"
[[ $(snapshots) == "uki_2 uki_3 " && $(wc -l <"$tmp/syncs") == 1 ]] || fail "only the oldest snapshot entries go" "$(snapshots)"
grep -Fxq MAX_SNAPSHOT_ENTRIES=auto "$tmp/limine" || fail "the limit is set" "$(<"$tmp/limine")"
: >"$tmp/syncs"
kernel_update
(( status == 0 )) && [[ ! -s $tmp/syncs && $(snapshots) == "uki_2 uki_3 " ]] || fail "an update with room trims nothing"
near_limit
echo 'LIMIT_USAGE_PERCENT=85' >>"$tmp/limine"
kernel_update
(( status == 1 )) && [[ $(snapshots) == "uki_1 uki_2 uki_3 " && ! -s $tmp/syncs ]] && ! grep -Fq MAX_SNAPSHOT_ENTRIES "$tmp/limine" ||
  fail "an owner's own limit is kept, and the update refused" "$(<"$tmp/err")"
near_limit
PATH="$tmp/bin:$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp"
echo 'LIMIT_USAGE_PERCENT=40' >>"$tmp/limine"
kernel_update
(( status == 1 )) && [[ ! -s $tmp/syncs ]] || fail "an owner's limit added after the block trims nothing" "$(<"$tmp/err")"
# Other files fill the ESP: trimming to the limit would take the newest entry, this update's way back.
near_limit 1
kernel_update
(( status == 1 )) && [[ ! -s $tmp/syncs && $(snapshots) == "uki_1 " ]] || fail "the newest snapshot entry is never trimmed" "$(snapshots)"
near_limit
TEST_SYNC_FAILS=1 kernel_update
(( status == 1 )) && grep -Fq "could not be trimmed" "$tmp/err" && grep -Fq "No package was changed" "$tmp/err" || fail "a failed trim refuses the update" "$(<"$tmp/err")"
near_limit
TEST_LIMINE="" TEST_ESP_USED_FILE=$tmp/used run --pacman <<<'usr/lib/modules/7.3.0-1-1-ARCH/vmlinuz'
(( status == 1 )) && [[ ! -s $tmp/syncs ]] || fail "a GRUB Mac trims nothing"
unset OMARCHY_LIMINE_DEFAULT OMARCHY_LIMINE_ESP_LIMIT OMARCHY_MACHINE_ID
pass "the first update on a Mac near the old 85% limit trims the oldest snapshot entries instead of aborting"

TEST_ESP_FOUND="" run --firmware --boot-image
(( status == 0 )) || fail "a root without a mounted system ESP (an image build) passes"
pass "without a system ESP there is nothing to check"

# limine-esp-limit: the ESP less the firmware's room, as a percentage; at most limine-snapper-sync's 85.
fresh_esp
export TEST_ESP_SIZE=$((200 << 10))
printf 'TARGET_OS_NAME="Omarchy"\nESP_PATH="/boot/efi"\n' >"$tmp/limine"
reserve=$(bash "$space" --esp "$esp" --firmware --boot-image --print-need)
percent=$(( ((200 << 10) - reserve) * 100 / (200 << 10) ))
PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp" || fail "limine-esp-limit succeeds"
[[ $(tail -n 2 "$tmp/limine") == "$(printf 'MAX_SNAPSHOT_ENTRIES=auto\nLIMIT_USAGE_PERCENT=%s' "$percent")" ]] || fail "the limit leaves the firmware's room" "$(cat "$tmp/limine")"
grep -Fxq 'ESP_PATH="/boot/efi"' "$tmp/limine" || fail "the rest of the defaults stay"
cp "$tmp/limine" "$tmp/limine.before"
PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp"
cmp -s "$tmp/limine" "$tmp/limine.before" || fail "a second run changes nothing" "$(cat "$tmp/limine")"
mib "$esp/vendorfw/more.cpio" 60
PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp"
reserve=$(bash "$space" --esp "$esp" --firmware --boot-image --print-need)
[[ $(grep -c '^LIMIT_USAGE_PERCENT=' "$tmp/limine") == 1 && $(tail -n 1 "$tmp/limine") == "LIMIT_USAGE_PERCENT=$(( ((200 << 10) - reserve) * 100 / (200 << 10) ))" ]] ||
  fail "a larger firmware moves the limit, once" "$(cat "$tmp/limine")"
TEST_ESP_SIZE=$((4 << 20)) PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp"
[[ $(tail -n 1 "$tmp/limine") == LIMIT_USAGE_PERCENT=85 ]] || fail "a large ESP keeps limine-snapper-sync's 85%" "$(cat "$tmp/limine")"
pass "snapshot kernels are limited to what leaves room for the next firmware and boot image"

for owner in 'LIMIT_USAGE_PERCENT=90' 'MAX_SNAPSHOT_ENTRIES=3' '  LIMIT_USAGE_PERCENT = 70'; do
  printf 'ESP_PATH="/boot/efi"\n%s\n' "$owner" >"$tmp/limine"
  cp "$tmp/limine" "$tmp/limine.before"
  PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp"
  cmp -s "$tmp/limine" "$tmp/limine.before" || fail "an owner's $owner is kept" "$(cat "$tmp/limine")"
done
rm "$tmp/limine"
PATH="$ROOT/bin:$PATH" bash "$limit" "$tmp/limine" "$esp" && [[ ! -e $tmp/limine ]] || fail "a Mac without Limine defaults gets none"
pass "an owner's own snapshot limits, or a Mac without Limine, are left alone"
