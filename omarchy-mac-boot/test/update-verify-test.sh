#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/test/fixtures/limine-mac.sh"

require_command gzip
require_command b2sum

# omarchy update runs update-verify through omarchy-lifecycle-dispatch once its
# packages, migrations and hooks are done. It is the boot check on the whole
# boot chain, read-only, with the reboot the update offers next still to come.
entrypoint=$ROOT/entrypoints/update-verify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$ROOT/install" "$tmp/stage"
staged=$tmp/stage/usr/lib/omarchy/mac-boot/update-verify
cmp -s "$entrypoint" "$staged" && [[ $(stat -c %a "$staged") == 755 ]] ||
  fail "update-verify is staged as the lifecycle dispatch entrypoint /usr/lib/omarchy/mac-boot/update-verify"
pass "the package ships update-verify where omarchy-lifecycle-dispatch runs it"

limine_mac_init "$tmp/mac"

tree_state() {
  find "$mac_root" -path "$mac_root/run" -prune -o -print0 | sort -z | xargs -0 stat -c '%n %s %Y %a' 2>/dev/null
  find "$mac_root" -path "$mac_root/run" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
}

# Runs update-verify on the fixture Mac; $1 is the running kernel release.
verify() {
  tree_state >"$tmp/before"
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin" "${1:-}")"
    [[ -z ${TEST_REBUILDS:-} ]] || export PATH="$TEST_REBUILDS:$PATH"
    export OMARCHY_MAC_BOOT_CTXR=$tmp/ctxr-stub
    bash "$entrypoint"
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
  tree_state >"$tmp/after"
  [[ -n ${TEST_REBUILDS:-} ]] || diff -q "$tmp/before" "$tmp/after" >/dev/null || fail "update-verify changes no boot file" "$(diff "$tmp/before" "$tmp/after")"
  [[ ! -s $mac_state/mounts && -z $(ls -A "$mac_root/run") ]] || fail "update-verify leaves nothing mounted"
}

expect_verified() {
  (( status == 0 )) || fail "$1 passes update-verify" "status $status: $(cat "$tmp/err")"
}

expect_refused() {
  local description=$1 reason=$2
  (( status == 1 )) || fail "$description fails update-verify" "status $status: $(cat "$tmp/out" "$tmp/err")"
  grep -Fq "$reason" "$tmp/err" || fail "$description is named" "$(cat "$tmp/err")"
  grep -Fq "do not reboot yet" "$tmp/err" && grep -Fq "sudo mkinitcpio -P && sudo update-m1n1 && sudo omarchy-mac-boot-update && sudo /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$tmp/err" ||
    fail "$description says not to reboot and how to rebuild the boot files" "$(cat "$tmp/err")"
}

limine_mac
verify
expect_verified "a Limine Mac running the installed kernel"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "update-verify reports what it verified" "$(cat "$tmp/out")"
! grep -Fq "owner-boot-chain" "$tmp/out" "$tmp/err" || fail "a Mac without /etc/omarchy-mac-boot/owner-boot-chain is not told about it" "$(cat "$tmp/out" "$tmp/err")"
verify 6.16.0-aurora9-ARCH
expect_verified "a Limine Mac whose update installed a new kernel"
grep -Fq "running 6.16.0-aurora9-ARCH, reboot pending" "$tmp/out" || fail "update-verify says the reboot is still to come" "$(cat "$tmp/out")"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[2]}" "${mac_dtbs[0]}" "${mac_dtbs[1]}"
verify
expect_verified "an m1n1 image holding the kernel's device trees in another order"
pass "update-verify passes a coherent boot chain, before and after the reboot, whatever order the device trees are in"

boot_bin_reason="m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $mac_kver's device trees, U-Boot and /etc/m1n1.conf as installed"

limine_mac
limine_mac_dtb "$mac_root/opt/t8103-j274.dtb" "from another kernel"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[@]:0:2}" /opt/t8103-j274.dtb
verify
expect_refused "an m1n1 image with a device tree the installed kernel does not ship" "$boot_bin_reason"

limine_mac
printf 'm1n1 stage 2 from the previous m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
verify
expect_refused "an m1n1 image with a stale m1n1" "$boot_bin_reason"

limine_mac
rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
verify
expect_refused "a Limine Mac without its UKI" "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"

limine_mac
printf 'the previous kernel\n' >"$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
limine_mac_menu
verify
expect_refused "a UKI carrying another kernel" "does not carry the installed $mac_kver kernel"

limine_mac
printf 'LIMINE, previous release\n' >"$mac_esp/EFI/BOOT/BOOTAA64.EFI"
verify
expect_refused "a loader slot with another Limine" "/boot/efi/EFI/BOOT/BOOTAA64.EFI is not the installed Limine"

limine_mac
printf 'usr/lib/modules/6.16.0-aurora9-ARCH/kernel/x.ko\n' >"$mac_state/initramfs"
verify 6.16.0-aurora9-ARCH
expect_refused "an initramfs built for the previous kernel" "does not hold the $mac_kver modules"

limine_mac
cp "$mac_state/initramfs" "$mac_state/boot-initramfs"
printf 'usr/lib/modules/6.16.0-aurora9-ARCH/kernel/x.ko\n' >"$mac_state/uki-initramfs"
verify 6.16.0-aurora9-ARCH
expect_refused "a Limine Mac whose UKI initramfs is stale while /boot/initramfs is current" \
  "the initramfs inside /boot/efi/EFI/Linux/omarchy_linux-aurora.efi does not hold the $mac_kver modules"

limine_mac
cp "$mac_state/initramfs" "$mac_state/uki-initramfs"
printf 'usr/lib/modules/6.16.0-aurora9-ARCH/kernel/x.ko\n' >"$mac_state/boot-initramfs"
verify 6.16.0-aurora9-ARCH
expect_verified "a Limine Mac whose UKI initramfs is current while /boot/initramfs is stale"
rm "$mac_root/boot/initramfs-linux-aurora.img"
verify 6.16.0-aurora9-ARCH
expect_verified "a Limine Mac whose UKI initramfs is current while /boot/initramfs is absent"
pass "update-verify refuses a wrong device tree, a stale m1n1, a missing or stale UKI, another Limine or a stale initramfs, and says not to reboot"

# The owner marker makes the check advisory. Without it, failures block updates.
expect_skipped() {
  local expected="Skipping boot verification: /etc/omarchy-mac-boot/owner-boot-chain is present; the owner manages this boot chain."
  if [[ -n ${1:-} ]]; then
    expected+=$'\n'"The packaged check would fail: $1. Remove the file to have updates verify again."
  fi
  (( status == 0 )) || fail "owner-managed verification succeeds" "$(cat "$tmp/out" "$tmp/err")"
  [[ ! -s $tmp/err ]] || fail "owner-managed verification has no checker errors" "$(cat "$tmp/err")"
  printf '%s\n' "$expected" | diff -u - "$tmp/out" || fail "owner-managed verification prints the skip and any advisory"
}
limine_mac
mkdir -p "$mac_root/etc/omarchy-mac-boot"
: >"$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
verify
expect_skipped
rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
verify
expect_skipped "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"
rm "$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
verify
expect_refused "a Limine Mac without its UKI after removing the owner marker" "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"
limine_mac
sed -i '/^linux-aurora$/d' "$mac_state/installed"
verify
expect_refused "a Mac with no packaged kernel" "cannot tell which kernel boots: neither linux-aurora nor linux-asahi installed"
mkdir -p "$mac_root/etc/omarchy-mac-boot"
: >"$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
verify
expect_skipped "cannot tell which kernel boots: neither linux-aurora nor linux-asahi installed"
pass "update-verify quietly checks with an owner marker and reports failures without blocking the update"

mkdir -p "$tmp/check-stub"
cat >"$tmp/check-stub/omarchy-apple-silicon-boot-check" <<'SH'
#!/bin/bash
echo 'checker output'
echo 'Apple Silicon boot check: warning: a checker warning' >&2
echo 'Apple Silicon boot check: first failure' >&2
echo 'Apple Silicon boot check: another failure' >&2
exit 1
SH
chmod +x "$tmp/check-stub/omarchy-apple-silicon-boot-check"
TEST_REBUILDS=$tmp/check-stub verify
expect_skipped "first failure"
pass "update-verify reports the first failure reason when the checker also emits other diagnostics"

# update-verify checks only what the next boot reads. What the full boot check
# also holds against a Mac, the next boot does not read, so it never fails an
# update: the full check still refuses it.
full_check() {
  set +e
  (
    eval "$(limine_mac_env "$ROOT/bin")"
    bash "$ROOT/bin/omarchy-apple-silicon-boot-check"
  ) >"$tmp/full-out" 2>"$tmp/full-err"
  full_status=$?
  set -e
}

beyond_boot_chain() {
  local description=$1 reason=$2
  full_check
  (( full_status == 1 )) && grep -Fq "$reason" "$tmp/full-err" ||
    fail "the full boot check refuses $description" "status $full_status: $(cat "$tmp/full-err")"
  verify
  expect_verified "$description"
}

limine_mac
limine_mac_luks
full_check
(( full_status == 0 )) || fail "the full boot check passes an encrypted Limine Mac" "$(cat "$tmp/full-err")"
verify
expect_verified "an encrypted Limine Mac"
limine_mac_luks 1
beyond_boot_chain "an encrypted Mac with a third LUKS keyslot" "throwaway LUKS keyslot still present"
limine_mac
printf 'M1N1_UPDATE_DISABLED=1\n' >>"$mac_root/etc/default/update-m1n1"
printf 'built by its owner\n' >>"$mac_esp/m1n1/boot.bin"
beyond_boot_chain "an m1n1 image its owner took over" "M1N1_UPDATE_DISABLED is set"
grep -Fq "m1n1/boot.bin is its owner's and is not checked" "$tmp/out" || fail "update-verify says it left m1n1 to its owner" "$(cat "$tmp/out")"
# A second kernel, older, with its own entry after the one the menu starts.
second_kernel() {
  local asahi=6.14.8-asahi1-1-ARCH
  mkdir -p "$mac_root/usr/lib/modules/$asahi/dtbs"
  printf 'linux-asahi kernel\n' >"$mac_root/usr/lib/modules/$asahi/vmlinuz"
  printf 'linux-asahi\n' >>"$mac_state/installed"
  printf '/usr/lib/modules/%s/vmlinuz\n' "$asahi" >"$mac_state/files-linux-asahi"
}
limine_mac
second_kernel
printf '  //linux-asahi\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-asahi.efi#0\n    cmdline: quiet\n' >>"$mac_esp/limine.conf"
beyond_boot_chain "a Mac with a second kernel installed" "cannot tell which kernel boots"
grep -Fq "running linux-aurora $mac_kver" "$tmp/out" || fail "update-verify checks the kernel the menu starts" "$(cat "$tmp/out")"
limine_mac
printf '/usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\n' "$mac_kver" >"$mac_state/drift-linux-aurora"
beyond_boot_chain "a kernel module that drifted from its mtree" "linux-aurora files do not match the package mtree"
pass "update-verify passes a healthy Mac with an extra keyslot, an owner-built m1n1, a second kernel or a drifted module"

# What the boot files are built from still has to match its package.
for drifted in "/usr/lib/modules/$mac_kver/vmlinuz" "${mac_dtbs[0]}"; do
  limine_mac
  printf '%s\n' "$drifted" >"$mac_state/drift-linux-aurora"
  verify
  expect_refused "a drifted ${drifted##*/}" "installed linux-aurora files do not match the package mtree: warning: linux-aurora: $drifted"
done
limine_mac
printf '/usr/lib/asahi-boot/m1n1.bin\n' >"$mac_state/drift-m1n1-aurora"
verify
expect_refused "a drifted m1n1" "installed m1n1-aurora files do not match the package mtree"
# With two kernels, the one the menu starts is checked, and it must boot.
limine_mac
second_kernel
{
  printf '/+Omarchy\n  //linux-asahi\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-asahi.efi#0\n    cmdline: quiet\n'
  sed 1d "$mac_esp/limine.conf"
} >"$tmp/limine.conf"
cp "$tmp/limine.conf" "$mac_esp/limine.conf"
verify
expect_refused "a Mac whose menu starts the second kernel first" "linux-asahi boots with m1n1, but m1n1 is not installed"
# A fresh image's database warnings explain nothing else pacman reports.
limine_mac
: >"$mac_state/fresh-image"
printf '/usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\n' "$mac_kver" >"$mac_state/drift-linux-aurora"
verify
expect_verified "a fresh image with a drifted module"
printf 'error: linux-aurora: could not read the mtree\n' >"$mac_state/report-linux-aurora"
verify
expect_refused "a package pacman cannot check, on a fresh image" "installed linux-aurora files do not match the package mtree: error: linux-aurora: could not read the mtree"
pass "update-verify still refuses a drifted kernel image, device tree or m1n1, or a package pacman cannot check, and checks the kernel the menu starts"

# linux-aurora-wip installs beside linux-aurora for testers to pick in the
# menu: its own release (never -ARCH, so update-m1n1 keeps linux-aurora's
# device trees in m1n1 stage 2) and its own entry, after linux-aurora's.
wip_release=6.17.0-2.r1453145.gfe6d813-1-aurora-wip
wip_kernel() {
  local modules=$mac_root/usr/lib/modules/${1:-$wip_release} dtb
  mkdir -p "$modules/dtbs"
  printf 'linux-aurora-wip kernel\n' >"$modules/vmlinuz"
  printf 'linux-aurora-wip\n' >"$modules/pkgbase"
  for dtb in "${mac_dtbs[@]}"; do
    limine_mac_dtb "$modules/dtbs/${dtb##*/}" "from aurora-wip"
  done
  printf '%s\n' linux-aurora-wip linux-aurora-wip-headers >>"$mac_state/installed"
  printf '  //linux-aurora-wip\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-aurora-wip.efi#0\n    cmdline: quiet\n' >>"$mac_esp/limine.conf"
}
limine_mac
wip_kernel
full_check
(( full_status == 0 )) || fail "the full boot check passes a Mac with linux-aurora-wip installed" "$(cat "$tmp/full-err")"
verify
expect_verified "a Mac with linux-aurora-wip after linux-aurora"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "update-verify checks linux-aurora beside linux-aurora-wip" "$(cat "$tmp/out")"
verify "$wip_release"
expect_verified "a Mac booted into linux-aurora-wip"
set +e
(
  eval "$(limine_mac_env "$ROOT/bin" "$wip_release")"
  bash "$ROOT/bin/omarchy-apple-silicon-boot-check"
) >"$tmp/full-out" 2>"$tmp/full-err"
full_status=$?
set -e
(( full_status == 1 )) && grep -Fq "running linux-aurora-wip $wip_release, not linux-aurora $mac_kver, which the boot menu starts first" "$tmp/full-err" ||
  fail "the full boot check names linux-aurora-wip as the running kernel" "status $full_status: $(cat "$tmp/full-err")"
limine_mac
wip_kernel
{
  printf '/+Omarchy\n  //linux-aurora-wip\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-aurora-wip.efi#0\n    cmdline: quiet\n'
  sed '1d; /\/\/linux-aurora-wip$/,$d' "$mac_esp/limine.conf"
} >"$tmp/limine.conf"
cp "$tmp/limine.conf" "$mac_esp/limine.conf"
verify
expect_refused "a menu that starts linux-aurora-wip first" "/boot/efi/limine.conf starts linux-aurora-wip first, not linux-aurora"
# A wip release ending in -ARCH and sorting above linux-aurora's would put its
# device trees in m1n1 stage 2 on the next update-m1n1.
limine_mac
wip_kernel 6.17.1-aurora1-ARCH
verify
expect_refused "a second kernel whose release update-m1n1 takes device trees from" "is not one of linux-aurora $mac_kver's"
pass "update-verify checks linux-aurora beside linux-aurora-wip, and refuses a menu that starts wip first or a stage built from wip's device trees"

limine_mac
limine_mac_luks
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$mac_kver" >"$mac_state/initramfs"
verify
expect_refused "an encrypted Mac whose initramfs cannot unlock the root" "does not contain sd-encrypt"

limine_mac
limine_mac_luks
cp "$mac_state/initramfs" "$mac_state/boot-initramfs"
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$mac_kver" >"$mac_state/uki-initramfs"
verify
expect_refused "an encrypted Limine Mac whose UKI initramfs lacks sd-encrypt while /boot/initramfs has it" \
  "the initramfs inside /boot/efi/EFI/Linux/omarchy_linux-aurora.efi does not contain sd-encrypt"

limine_mac
limine_mac_luks
cp "$mac_state/initramfs" "$mac_state/uki-initramfs"
printf 'usr/lib/modules/%s/kernel/x.ko\nusr/bin/init\n' "$mac_kver" >"$mac_state/boot-initramfs"
verify
expect_verified "an encrypted Limine Mac whose UKI initramfs has sd-encrypt while /boot/initramfs lacks it"
rm "$mac_root/boot/initramfs-linux-aurora.img"
verify
expect_verified "an encrypted Limine Mac whose UKI initramfs has sd-encrypt while /boot/initramfs is absent"

limine_mac
limine_mac_luks
mac_cmdline="root=UUID=r rw rootflags=subvol=@ quiet"
limine_mac_menu
verify
expect_refused "an encrypted Mac whose Limine entry does not unlock the root" "does not set rd.luks.name= for the encrypted root"
pass "update-verify still refuses an encrypted Mac whose next boot cannot unlock its root"

# A Mac installed before Omarchy's images unlocks its root in the busybox
# init, through the encrypt hook and GRUB's cryptdevice=, with /boot on the ESP.
limine_mac
limine_mac_busybox
verify
expect_verified "a busybox encrypt Mac booting GRUB from the ESP at /boot"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "update-verify reports what it verified" "$(cat "$tmp/out")"
verify 6.16.0-aurora9-ARCH
expect_verified "a busybox encrypt Mac whose update installed a new kernel"
sed -i 's/ cryptdevice=[^ ]*//' "$mac_root/boot/grub/grub.cfg"
verify
expect_refused "a busybox encrypt Mac whose GRUB entry lost cryptdevice=" "/boot/grub/grub.cfg does not set cryptdevice= for the root the encrypt hook unlocks"
limine_mac
limine_mac_busybox
sed -i 's/ quiet$/ rootflags=x-systemd.device-timeout=0 quiet/' "$mac_root/boot/grub/grub.cfg"
verify
expect_refused "a busybox encrypt Mac with a second rootflags=" "passes more than one rootflags="
limine_mac
limine_mac_busybox
sed -i 's/UUID=0422663f/UUID=1111663f/' "$mac_root/boot/grub/grub.cfg"
verify
expect_refused "a busybox encrypt Mac whose cryptdevice= names another partition" "cryptdevice= does not name the LUKS partition of the root"
pass "update-verify passes a busybox encrypt Mac and refuses one whose GRUB entry cannot unlock or mount its root"

# The disk passphrase prompt types with the layout the boot image carries.
danish=(KEYMAP=dk-latin1 XKBLAYOUT=dk XKBMODEL=pc105)
limine_mac
limine_mac_luks
limine_mac_keyboard "${danish[@]}"
verify
expect_verified "an encrypted Limine Mac whose UKI carries its Danish layout"
rm "$mac_state/initrd-tree/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz"
verify
expect_refused "an encrypted Limine Mac whose UKI lacks the keymap" "missing the dk-latin1 keymap"
limine_mac_keyboard "${danish[@]}"
printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$mac_state/initrd-tree/etc/vconsole.conf"
verify
expect_refused "an encrypted Limine Mac whose UKI was built before the layout changed" "does not carry the keyboard layout of /etc/vconsole.conf (KEYMAP=dk-latin1 XKBLAYOUT=dk)"
limine_mac
limine_mac_busybox
limine_mac_keyboard "${danish[@]}"
verify
expect_verified "a busybox encrypt Mac whose initramfs carries its Danish layout"
rm "$mac_state/initrd-tree/keymap.bin"
verify
expect_refused "a busybox encrypt Mac whose initramfs lacks the compiled keymap" "missing the keymap hook's keymap.bin"
limine_mac
limine_mac_keyboard "${danish[@]}"
rm -rf "$mac_state/initrd-tree"
verify
expect_verified "an unencrypted Mac, which has no passphrase prompt"
pass "update-verify refuses an encrypted Mac whose boot image does not carry its keyboard layout"

# After a snapshot restore across a boot update the ESP can stay newer than every
# package, so the marker that restore left has update-verify rebuild it until
# the rebuild finishes.
stubs=$tmp/rebuild-stubs
mkdir -p "$stubs"
cat >"$stubs/mkinitcpio" <<'SH'
#!/bin/bash
echo mkinitcpio >>"$REBUILD_LOG"
SH
cat >"$stubs/update-m1n1" <<'SH'
#!/bin/bash
echo update-m1n1 >>"$REBUILD_LOG"
[[ -z ${REBUILD_FAILS:-} ]] || exit 1
cp "$GOOD_BOOT_BIN" "$ESP_BOOT_BIN"
SH
cat >"$tmp/ctxr-stub" <<'SH'
#!/bin/bash
echo omarchy-mac-boot-ctxr >>"$REBUILD_LOG"
[[ $* == --verify ]] || exit 2
[[ -z ${CTXR_NO_ESP:-} ]] || exit 3
[[ -z ${CTXR_FAILS:-} ]] || exit 1
SH
chmod +x "$tmp/ctxr-stub"
cat >"$stubs/omarchy-mac-boot-update" <<'SH'
#!/bin/bash
echo omarchy-mac-boot-update >>"$REBUILD_LOG"
[[ -z ${BOOT_UPDATE_FAILS:-} ]] || exit 1
SH
chmod +x "$stubs"/*
export REBUILD_LOG=$tmp/rebuilds GOOD_BOOT_BIN=$tmp/good-boot.bin

limine_mac
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
expect_verified "a coherent Mac without the rollback marker"
[[ ! -s $REBUILD_LOG ]] || fail "update-verify rebuilds nothing without the rollback marker" "$(cat "$REBUILD_LOG")"
pass "update-verify rebuilds nothing, boot-ctxr.bin included, without the rollback marker"

limine_mac
export ESP_BOOT_BIN=$mac_esp/m1n1/boot.bin
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
expect_verified "a coherent Mac with the rollback marker"
[[ $(tr '\n' ' ' <"$REBUILD_LOG") == "omarchy-mac-boot-ctxr " ]] || fail "a coherent Mac with the marker rebuilds only boot-ctxr.bin, which the check cannot see" "$(cat "$REBUILD_LOG")"
[[ ! -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a coherent Mac clears the marker once boot-ctxr.bin is rebuilt"
pass "update-verify rebuilds boot-ctxr.bin and clears the rollback marker when the other boot files already match"

limine_mac
cp "$ESP_BOOT_BIN" "$GOOD_BOOT_BIN"
printf 'm1n1 stage 2 from the next m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
expect_verified "a Mac with newer boot files after a rollback"
[[ $(tr '\n' ' ' <"$REBUILD_LOG") == "mkinitcpio update-m1n1 omarchy-mac-boot-update omarchy-mac-boot-ctxr " ]] || fail "the rollback rebuild runs in order" "$(cat "$REBUILD_LOG")"
[[ ! -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a finished rebuild clears the marker"
pass "update-verify rebuilds newer boot files after a rollback, with no package change"

limine_mac
cp "$ESP_BOOT_BIN" "$GOOD_BOOT_BIN"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
CTXR_FAILS=1 TEST_REBUILDS=$stubs verify
grep -qx omarchy-mac-boot-update "$REBUILD_LOG" || fail "a failed boot-ctxr.bin rebuild skips the boot menu rebuild" "$(cat "$REBUILD_LOG")"
[[ $status != 0 ]] && grep -Fq "do not reboot yet" "$tmp/err" || fail "a failed boot-ctxr.bin rebuild passes verification" "$(cat "$tmp/err")"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a failed boot-ctxr.bin rebuild clears the marker"
grep -Fq "Fix what was reported above, then rebuild them:" "$tmp/err" &&
  grep -Fxq "  sudo /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$tmp/err" &&
  grep -Fq "create /etc/omarchy-mac-boot/owner-boot-chain" "$tmp/err" && ! grep -Fq "rebuilds them again" "$tmp/err" ||
  fail "a failed boot-ctxr.bin rebuild says how to rebuild it and the way out" "$(cat "$tmp/err")"
# boot.bin is right now, so the next update's check passes; boot-ctxr.bin is still retried.
: >"$REBUILD_LOG"
CTXR_FAILS=1 TEST_REBUILDS=$stubs verify
[[ $(tr '\n' ' ' <"$REBUILD_LOG") == "omarchy-mac-boot-ctxr " ]] || fail "the next update retries only the boot-ctxr.bin rebuild" "$(cat "$REBUILD_LOG")"
[[ $status != 0 ]] && grep -Fq "do not reboot yet" "$tmp/err" || fail "a boot-ctxr.bin rebuild that fails again passes verification" "$(cat "$tmp/err")"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a boot-ctxr.bin rebuild that fails again clears the marker"
grep -Fxq "  sudo /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$tmp/err" && grep -Fq "or create /etc/omarchy-mac-boot/owner-boot-chain" "$tmp/err" ||
  fail "a failed boot-ctxr.bin retry prints the ctxr rebuild and the way out" "$(cat "$tmp/err")"
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
expect_verified "a boot-ctxr.bin rebuild that succeeds on the next update"
[[ $(tr '\n' ' ' <"$REBUILD_LOG") == "omarchy-mac-boot-ctxr " ]] || fail "the retry rebuilds only boot-ctxr.bin" "$(cat "$REBUILD_LOG")"
[[ ! -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a boot-ctxr.bin rebuild that succeeds on retry clears the marker"
pass "a failed boot-ctxr.bin rebuild rebuilds the menu, fails verification, keeps the marker, and is retried until it succeeds"

# A boot menu rebuild that fails after update-m1n1 repaired boot.bin: the check passes,
# and the message is the full rebuild, with nothing about boot-ctxr.bin's TARGET.
limine_mac
cp "$ESP_BOOT_BIN" "$GOOD_BOOT_BIN"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
BOOT_UPDATE_FAILS=1 TEST_REBUILDS=$stubs verify
[[ $(tr '\n' ' ' <"$REBUILD_LOG") == "mkinitcpio update-m1n1 omarchy-mac-boot-update " ]] || fail "a failed boot menu rebuild stops the rebuild" "$(cat "$REBUILD_LOG")"
[[ $status == 1 ]] && grep -Fq "do not reboot yet" "$tmp/err" || fail "a failed boot menu rebuild passes verification" "status $status: $(cat "$tmp/err")"
! grep -Fq "This Mac might not boot" "$tmp/err" || fail "a failed boot menu rebuild is reported by the boot check, not the rebuild" "$(cat "$tmp/err")"
grep -Fxq "  sudo mkinitcpio -P && sudo update-m1n1 && sudo omarchy-mac-boot-update && sudo /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$tmp/err" ||
  fail "a failed boot menu rebuild prints the full rebuild" "$(cat "$tmp/err")"
! grep -Fq "TARGET" "$tmp/err" && ! grep -Fq "owner-boot-chain" "$tmp/err" || fail "a failed boot menu rebuild is told about boot-ctxr.bin's TARGET" "$(cat "$tmp/err")"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a failed boot menu rebuild clears the marker"
pass "a failed boot menu rebuild prints the full rebuild, not boot-ctxr.bin's way out, and keeps the marker"

# boot-ctxr.bin could not be looked at, with no ESP mounted: the marker stays for the next
# update, with a note, and the reboot is still offered.
limine_mac
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
CTXR_NO_ESP=1 TEST_REBUILDS=$stubs verify
expect_verified "a Mac whose boot-ctxr.bin could not be checked"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "an unchecked boot-ctxr.bin clears the marker"
grep -Fq "The system ESP is not mounted at /boot/efi or /boot, so the boot-ctxr.bin of an M4 or later was not checked" "$tmp/err" && ! grep -Fq "do not reboot yet" "$tmp/err" ||
  fail "an unchecked boot-ctxr.bin is noted without holding back the reboot" "$(cat "$tmp/err")"
pass "an unchecked boot-ctxr.bin keeps the marker and still offers the reboot"

limine_mac
printf 'm1n1 stage 2 from the next m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
REBUILD_FAILS=1 TEST_REBUILDS=$stubs verify
expect_refused "a rollback rebuild that fails" "m1n1/boot.bin"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a failed rebuild keeps the marker for the next update"
pass "update-verify refuses when the rollback rebuild fails, and tries again next time"

# A rebuild whose commands succeed but leave the check failing keeps the marker.
limine_mac
printf 'm1n1 stage 2 from the next m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
cp "$ESP_BOOT_BIN" "$GOOD_BOOT_BIN"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
expect_refused "a rebuild that does not converge" "m1n1/boot.bin"
[[ -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "a rebuild that does not converge keeps the marker"
pass "update-verify keeps the marker until the check passes"

# An owner-managed boot chain never rebuilds here, and drops the marker.
limine_mac
mkdir -p "$mac_root/etc/omarchy-mac-boot"
printf 'hand-built chain\n' >"$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
printf 'm1n1 stage 2 from the next m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
: >"$REBUILD_LOG"
TEST_REBUILDS=$stubs verify
[[ ! -s $REBUILD_LOG && ! -e $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "an owner-managed chain rebuilds nothing and drops the marker"
pass "update-verify leaves an owner-managed boot chain to its owner"

