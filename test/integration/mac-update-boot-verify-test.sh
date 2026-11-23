#!/bin/bash
# omarchy update's boot verification running omarchy-mac-boot's real update-verify
# on a fixture Limine Mac: a coherent chain passes, an incoherent one fails the update.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
source "$BOOT/test/fixtures/limine-mac.sh"

require_platform_fixtures "omarchy update's boot checks on platform fixtures"
require_command gzip
require_command b2sum

# omarchy update runs inside the runtime's sudo boundary fixture, as upstream's
# update-boot-verify test runs it: every step but its boot check is a stub, and
# the boot check runs the real omarchy-update-boot, dispatcher and detector.
source "$OMARCHY_TEST_RUNTIME/test/shell.d/fixtures/sudo-boundary-test.sh"
copy_boundary_file bin/omarchy-update
rm "$SUDO_TEST_ROOT/bin/omarchy-update-boot"
for command in omarchy-update-boot omarchy-lifecycle-dispatch omarchy-hw-platform; do
  ln -sfn "$ROOT/bin/$command" "$SUDO_TEST_ROOT/bin/$command"
done
export OMARCHY_UPDATE_LOGGED=1

tmp=$boundary_tmp/mac-update
mkdir -p "$tmp"
fake_platform "$tmp/aarch64-apple" "$(runtime_platform aarch64-apple)"

# omarchy update -y on platform $1, with the boot package's entrypoints in the
# lifecycle root $2. The update's PATH is fixed, so uname goes beside the stubs.
run_update() {
  local platform=$1 lifecycle=$2
  reset_boundary
  cp "$tmp/$platform/bin/uname" "$SUDO_TEST_ROOT/bin/uname"
  status=0
  OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_LIFECYCLE_ROOT="$lifecycle" \
    "$SUDO_TEST_ROOT/bin/omarchy-update" -y >"$tmp/out" 2>"$tmp/err" || status=$?
}

ran() {
  grep -q "^step:$1" "$SUDO_TEST_LOG"
}

reboot_offered() {
  ran 'omarchy-update-restart --reboot-only'
}

# omarchy-mac-boot's own update-verify, on the fixture Mac. The dispatcher runs
# entrypoints with an empty environment, so this one puts the fixture's back
# before it runs the real entrypoint and boot check. $1 is the running kernel.
mac_boot_package() {
  local lifecycle=$tmp/mac-boot entrypoint=$tmp/mac-boot/usr/lib/omarchy/mac-boot/update-verify
  rm -rf "$lifecycle"
  mkdir -p "${entrypoint%/*}"
  {
    printf '#!/bin/bash\n'
    limine_mac_env "$BOOT/bin" "${1:-}"
    printf 'exec bash %q\n' "$BOOT/entrypoints/update-verify"
  } >"$entrypoint"
  chmod -R go-w "$lifecycle"
  chmod 755 "$entrypoint"
}


# omarchy-mac-boot's update-verify on a Limine Mac, end to end.
limine_mac_init "$tmp/mac"
limine_mac
mac_boot_package
run_update aarch64-apple "$tmp/mac-boot"
(( status == 0 )) || fail "apple: an update that leaves a coherent boot chain succeeds" "status $status: $(cat "$tmp/out" "$tmp/err")"
reboot_offered || fail "apple: a verified update offers the reboot" "$(cat "$SUDO_TEST_LOG")"
grep -Fq "running linux-aurora $mac_kver; installed boot files match" "$tmp/out" || fail "apple: the update shows what it verified" "$(cat "$tmp/out")"
mac_boot_package 6.16.0-aurora9-ARCH
run_update aarch64-apple "$tmp/mac-boot"
(( status == 0 )) && reboot_offered ||
  fail "apple: an update that installed a new kernel is verified before its reboot" "status $status: $(cat "$tmp/out" "$tmp/err")"
pass "apple: an update that leaves a coherent boot chain passes verification and offers the reboot"

# Injected incoherence: the update fails, says why and what to do, and does not
# offer the reboot. Everything else still runs.
blocked() {
  local description=$1 reason=$2
  run_update aarch64-apple "$tmp/mac-boot"
  (( status == 1 )) || fail "apple: $description fails the update" "status $status: $(cat "$tmp/err")"
  ! reboot_offered || fail "apple: $description offers no reboot"
  ran 'omarchy-update-stay-awake stop' || fail "apple: $description still releases Stay Awake" "$(cat "$SUDO_TEST_LOG")"
  grep -Fq "$reason" "$tmp/err" || fail "apple: $description is explained" "$(cat "$tmp/err")"
  grep -Fq "do not reboot yet" "$tmp/err" && grep -Fq "The update is not finished" "$tmp/err" ||
    fail "apple: $description says the update is not finished and not to reboot" "$(cat "$tmp/err")"
}
mac_boot_package
limine_mac
limine_mac_dtb "$mac_root/opt/t8103-j274.dtb" "from another kernel"
limine_mac_boot_bin "$mac_root/usr/lib/asahi-boot/m1n1.bin" "${mac_dtbs[@]:0:2}" /opt/t8103-j274.dtb
blocked "a wrong device tree in m1n1/boot.bin" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $mac_kver's device trees"
limine_mac
printf 'm1n1 stage 2 from the previous m1n1-aurora\n' >"$tmp/m1n1.bin"
limine_mac_boot_bin "$tmp/m1n1.bin" "${mac_dtbs[@]}"
blocked "a stale m1n1" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1"
limine_mac
rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
blocked "a missing UKI" "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"
pass "apple: a wrong device tree, a stale m1n1 or a missing UKI fails the update, explained, with no reboot offered"

# The owner marker lets the update finish with a reboot even if the check fails.
owner_update() {
  local expected="Skipping boot verification: /etc/omarchy-mac-boot/owner-boot-chain is present; the owner manages this boot chain."
  if [[ -n ${1:-} ]]; then
    expected+=$'\n'"The packaged check would fail: $1. Remove the file to have updates verify again."
  fi
  run_update aarch64-apple "$tmp/mac-boot"
  (( status == 0 )) && reboot_offered ||
    fail "apple: an update on an owner-managed boot chain finishes and offers the reboot" "status $status: $(cat "$tmp/out" "$tmp/err")"
  [[ ! -s $tmp/err ]] || fail "apple: an owner-managed chain emits no checker errors" "$(cat "$tmp/err")"
  grep -E 'Skipping boot verification:|The packaged check would fail:|Apple Silicon boot check:|Verify the Apple Silicon boot files' "$tmp/out" >"$tmp/verification" ||
    fail "apple: an owner-managed boot chain explains the skip" "$(cat "$tmp/out")"
  printf '%s\n' "$expected" | diff -u - "$tmp/verification" || fail "apple: the update shows the skip and any advisory"
}

limine_mac
mkdir -p "$mac_root/etc/omarchy-mac-boot"
: >"$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
owner_update
pass "apple: a passing check with the owner marker prints only the skip line and offers the reboot"

rm "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
owner_update "/boot/efi/EFI/Linux/omarchy_linux-aurora.efi (the Limine UKI) is missing"
pass "apple: a failing check with the owner marker prints one advisory and offers the reboot"

limine_mac
mkdir -p "$mac_root/etc/omarchy-mac-boot"
: >"$mac_root/etc/omarchy-mac-boot/owner-boot-chain"
manifest=$mac_root/etc/omarchy-mac-boot/owner-boot-chain.sha256
owner_uki=boot/efi/EFI/Linux/omarchy_linux-owner.efi
owner_stage2=boot/efi/m1n1/boot-ctxr.bin
owner_tree=boot/efi/pinned.dtb
cp "$mac_esp/EFI/Linux/omarchy_linux-aurora.efi" "$mac_root/$owner_uki"
cp "$mac_esp/m1n1/boot.bin" "$mac_root/$owner_stage2"
cp "$mac_root${mac_dtbs[0]}" "$mac_root/$owner_tree"
sed -i '1i default_entry: Omarchy/linux-owner' "$mac_esp/limine.conf"
printf '  //linux-owner\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-owner.efi#%s\n' \
  "$(b2sum "$mac_root/$owner_uki" | cut -d' ' -f1)" >>"$mac_esp/limine.conf"

record_owner_manifest() {
  (cd "$mac_root" && sha256sum boot/efi/limine.conf boot/efi/EFI/BOOT/BOOTAA64.EFI "$owner_stage2" "$owner_tree" "$@") >"$manifest"
}
owner_refused() {
  run_update aarch64-apple "$tmp/mac-boot"
  (( status == 1 )) && ! reboot_offered ||
    fail "apple: owner verification refuses $1 and offers no reboot" "status $status: $(cat "$tmp/out" "$tmp/err")"
  grep -Fq "$2" "$tmp/err" && grep -Fq "do not reboot yet" "$tmp/err" ||
    fail "apple: explains why owner verification refused $1" "$(cat "$tmp/err")"
}

record_owner_manifest "$owner_uki"
run_update aarch64-apple "$tmp/mac-boot"
(( status == 0 )) && reboot_offered &&
  grep -Fq "Owner-managed boot files verified against the approved manifest." "$tmp/out" &&
  ! grep -Fq "The packaged check would fail" "$tmp/out" ||
  fail "apple: the approved custom default verifies with the stock entry listed first" "$(cat "$tmp/out" "$tmp/err")"

record_owner_manifest boot/efi/EFI/Linux/omarchy_linux-aurora.efi
owner_refused "a manifest covering only a nondefault UKI" "must cover the named Omarchy default entry"
record_owner_manifest "$owner_uki"
chmod g+w "$manifest"
owner_refused "a group-writable manifest" "writable only by its owner"
chmod g-w "$manifest"

cp "$mac_root/$owner_stage2" "$tmp/stage2"
printf 'changed Stage 2\n' >>"$mac_root/$owner_stage2"
: >"$mac_root/boot/.omarchy-mac-rolled-back"
owner_refused "a changed Aura Stage 2" "boot-ctxr.bin: FAILED"
[[ -f $mac_root/boot/.omarchy-mac-rolled-back ]] || fail "apple: failure retains the rollback marker"
cp "$tmp/stage2" "$mac_root/$owner_stage2"

sed -i '/path: .*omarchy_linux-owner.efi/s/linux-owner/linux-aurora/' "$mac_esp/limine.conf"
record_owner_manifest "$owner_uki"
owner_refused "a default entry targeting another UKI" "does not point to the recorded UKI"
pass "apple: a verified owner chain completes the update and any mismatch prevents a reboot"
