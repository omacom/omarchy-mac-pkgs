#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
printf '#!/bin/bash\nexit "${TEST_NOT_APPLE:-0}"\n' >"$test_tmp/bin/omarchy-hw-apple-silicon"
printf '#!/bin/bash\nexit "${TEST_NOT_LIMINE:-1}"\n' >"$test_tmp/bin/omarchy-mac-limine-active"
for name in grub-probe grub-mkconfig; do
  printf '#!/bin/bash\nexit 0\n' >"$test_tmp/bin/$name"
done
for name in update-grub omarchy-mac-boot-update; do
  cat >"$test_tmp/bin/$name" <<'STUB'
#!/bin/bash
echo "${0##*/}" >>"$TEST_CALLS"
exit "${TEST_UPDATE_FAILURE:-0}"
STUB
done
chmod +x "$test_tmp/bin"/*
export PATH="$test_tmp/bin:$ROOT/bin:$PATH" TEST_CALLS="$test_tmp/calls"
export OMARCHY_GRUB_DEFAULT="$test_tmp/grub" OMARCHY_GRUB_CONSOLE_PENDING="$test_tmp/state/pending"
export OMARCHY_MKINITCPIO_CONF_DIR="$test_tmp/mkinitcpio.conf.d" OMARCHY_MKINITCPIO_PRESET_DIR="$test_tmp/presets"
export OMARCHY_MKINITCPIO_KERNEL=linux-asahi
# No host device tree, systemd or kernel parameters: the M4 cases write their own.
printf '#!/bin/bash\nexit "${TEST_CHROOT:-1}"\n' >"$test_tmp/bin/systemd-detect-virt"
chmod +x "$test_tmp/bin/systemd-detect-virt"
mkdir -p "$test_tmp/run-systemd"
export OMARCHY_SYSTEMD_RUN="$test_tmp/run-systemd" OMARCHY_DEVICE_TREE_COMPATIBLE="$test_tmp/compatible"
export OMARCHY_APPLE_DART_PARAMETERS="$test_tmp/apple_dart"
systemd_conf="$ROOT/test/fixtures/mkinitcpio/systemd.conf"
busybox_conf="$ROOT/test/fixtures/mkinitcpio/busybox-encrypt.conf"
run() {
  OMARCHY_MKINITCPIO_CONF="${MKINITCPIO_CONF:-$systemd_conf}" bash -e -c 'source "$1"' _ "$ROOT/setup/grub-console.sh"
}
cat >"$test_tmp/grub" <<'CONF'
GRUB_VIDEO_BACKEND="obsolete"
GRUB_CMDLINE_LINUX="ignored"
#GRUB_VIDEO_BACKEND="unused"
GRUB_VIDEO_BACKEND="old"
GRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_FONT="/keep/font.pf2"
CONF
cp "$test_tmp/grub" "$test_tmp/original"
TEST_NOT_APPLE=1 run
OMARCHY_MAC_IMAGE_BUILD=1 run
cmp -s "$test_tmp/grub" "$test_tmp/original" || fail "non-Apple and deferred image paths are untouched"
[[ ! -e $TEST_CALLS ]] || fail "deferred runs do not update boot files"
pass "non-Apple and image preparation remain unchanged"

if TEST_UPDATE_FAILURE=7 run; then fail "failed regeneration is reported"; fi
[[ -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "failed regeneration remains pending"
grep -Fxq 'GRUB_VIDEO_BACKEND="efi_gop"' "$test_tmp/grub" || fail "GOP backend is pinned"
(( $(grep -c '^GRUB_VIDEO_BACKEND=' "$test_tmp/grub") == 1 )) || fail "duplicate backend assignments are collapsed"
grep -Fxq 'GRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@,x-systemd.device-timeout=0"' "$test_tmp/grub" || fail "last cmdline and encryption options are preserved, the wait joining its rootflags="
grep -Fxq 'GRUB_FONT="/keep/font.pf2"' "$test_tmp/grub" || fail "visual settings remain untouched"
run
[[ ! -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "successful retry clears pending regeneration"
(( $(wc -l <"$TEST_CALLS") == 2 )) || fail "retry regenerates unchanged defaults"
run
(( $(wc -l <"$TEST_CALLS") == 2 )) || fail "configured defaults are idempotent"
pass "GOP and root wait preserve effective cmdline and retry regeneration"

# Existing Limine installs need their UKI rebuilt from the edited defaults.
sed -i 's/,x-systemd.device-timeout=0//' "$test_tmp/grub"
TEST_NOT_LIMINE=0 run
[[ $(tail -n 1 "$TEST_CALLS") == "omarchy-mac-boot-update" ]] || fail "Limine command-line edits rebuild the active UKI"
pass "active Limine uses the coordinated boot updater"

# The same defaults are required by a fresh image with no GRUB installed.
sed -i 's/,x-systemd.device-timeout=0//' "$test_tmp/grub"
OMARCHY_GRUB_PROBE=omarchy-test-no-grub run
(( $(wc -l <"$TEST_CALLS") == 3 )) || fail "a fresh no-GRUB image does not regenerate GRUB"
grep -Fq 'rootflags=subvol=@,x-systemd.device-timeout=0' "$test_tmp/grub" || fail "no-GRUB image still gets the root wait"
pass "fresh no-GRUB images receive shared command-line defaults"

# A systemd initramfs merges every rootflags=, so the wait joins a rootflags=
# the line already has; mkinitcpio's busybox init keeps only the last one,
# which would drop 10_linux's rootflags=subvol=@, so there the wait never goes
# on and an old one comes off (omarchy-mx-mac #238/#248).
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0"\n' >"$test_tmp/grub"
run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=x-systemd.device-timeout=0"' "$test_tmp/grub" ||
  fail "a systemd initramfs gets the wait as its own rootflags=" "$(cat "$test_tmp/grub")"
run
(( $(grep -c 'x-systemd.device-timeout=0' "$test_tmp/grub") == 1 )) || fail "the wait is not added twice"
pass "on a systemd initramfs the wait never adds a second rootflags= beside the Mac's own"

printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX=""\nGRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 cryptdevice=UUID=0422663f:root:allow-discards"\n' >"$test_tmp/grub"
cp "$test_tmp/grub" "$test_tmp/busybox-original"
MKINITCPIO_CONF=$busybox_conf run
cmp -s "$test_tmp/grub" "$test_tmp/busybox-original" || fail "a busybox initramfs gets no second rootflags=" "$(cat "$test_tmp/grub")"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=x-systemd.device-timeout=0 rootflags=noatime,x-systemd.device-timeout=0"\n' >"$test_tmp/grub"
MKINITCPIO_CONF=$busybox_conf run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=noatime"' "$test_tmp/grub" ||
  fail "the wait comes off a busybox Mac's line" "$(cat "$test_tmp/grub")"
pass "a busybox initramfs gets no root-device wait, and loses one it had"

# The HOOKS mkinitcpio builds with include the drop-ins, in version order, and
# a preset that names its configuration builds without them.
mkdir -p "$OMARCHY_MKINITCPIO_CONF_DIR"
printf 'HOOKS=(base udev block filesystems)\n' >"$test_tmp/stock.conf"
printf 'HOOKS=(base systemd block filesystems)\n' >"$OMARCHY_MKINITCPIO_CONF_DIR/91-test.conf"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0"\n' >"$test_tmp/grub"
MKINITCPIO_CONF="$test_tmp/stock.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=x-systemd.device-timeout=0"' "$test_tmp/grub" ||
  fail "a drop-in that makes the initramfs systemd keeps the wait" "$(cat "$test_tmp/grub")"
printf 'HOOKS=(base udev block encrypt filesystems)\n' >"$OMARCHY_MKINITCPIO_CONF_DIR/100-local.conf"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0"\n' >"$test_tmp/grub"
MKINITCPIO_CONF="$test_tmp/stock.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0"' "$test_tmp/grub" || fail "100-local.conf applies after 91-test.conf" "$(cat "$test_tmp/grub")"
rm "$OMARCHY_MKINITCPIO_CONF_DIR/100-local.conf"
mkdir -p "$OMARCHY_MKINITCPIO_PRESET_DIR"
# Presets are Bash: quote paths, and exercise a space even in CI checkouts
# whose own paths contain none.
preset_config="$test_tmp/preset config.conf"
cp "$busybox_conf" "$preset_config"
printf 'PRESETS=(default)\nALL_config=%q\n' "$preset_config" >"$OMARCHY_MKINITCPIO_PRESET_DIR/linux-asahi.preset"
MKINITCPIO_CONF="$test_tmp/stock.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0"' "$test_tmp/grub" || fail "the preset's configuration, without drop-ins, decides" "$(cat "$test_tmp/grub")"
rm -rf "$OMARCHY_MKINITCPIO_CONF_DIR" "$OMARCHY_MKINITCPIO_PRESET_DIR"
MKINITCPIO_CONF="$test_tmp/missing.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=x-systemd.device-timeout=0"' "$test_tmp/grub" ||
  fail "an unreadable configuration keeps the wait, as every image boots systemd" "$(cat "$test_tmp/grub")"
pass "the initramfs kind comes from the preset, mkinitcpio.conf and its drop-ins in mkinitcpio's order"

# The M4 Macs' native display: both switches, only where the running kernel has them.
display='apple_dart.j713_dcp=1 apple_dart.j713_display=1'
printf 'apple,j604\0apple,t8132\0apple,arm-platform\0' >"$test_tmp/compatible"
mkdir -p "$OMARCHY_APPLE_DART_PARAMETERS"
touch "$OMARCHY_APPLE_DART_PARAMETERS/j713_dcp" "$OMARCHY_APPLE_DART_PARAMETERS/j713_display"
rm -f "$TEST_CALLS"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@,x-systemd.device-timeout=0"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$test_tmp/grub"
if TEST_UPDATE_FAILURE=7 TEST_NOT_LIMINE=0 run; then fail "a failed M4 rebuild is reported"; fi
[[ -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "a failed M4 rebuild stays pending"
grep -Fxq "GRUB_CMDLINE_LINUX=\"rd.luks.uuid=luks-id rootflags=subvol=@,x-systemd.device-timeout=0 $display\"" "$test_tmp/grub" ||
  fail "an M4 gets both display switches after its own options" "$(cat "$test_tmp/grub")"
TEST_NOT_LIMINE=0 run
[[ ! -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "a successful M4 retry clears the pending state"
[[ $(tail -n 1 "$TEST_CALLS") == omarchy-mac-boot-update ]] || fail "an M4 on Limine rebuilds its UKI"
cp "$test_tmp/grub" "$test_tmp/m4-configured"
calls=$(wc -l <"$TEST_CALLS")
run
cmp -s "$test_tmp/grub" "$test_tmp/m4-configured" || fail "the M4 defaults are idempotent"
[[ $(wc -l <"$TEST_CALLS") == "$calls" ]] || fail "a configured M4 is not rebuilt again"
pass "an M4 whose kernel has the display switches gets both, with retry and idempotence"

printf 'UUID=test-root / btrfs subvol=@ 0 0\n' >"$test_tmp/fstab"
printf 'KERNEL_CMDLINE[default]=""\n' >"$test_tmp/limine"
mkdir -p "$test_tmp/limine-entry-tool.d"
OMARCHY_LIMINE_DEFAULT="$test_tmp/limine" OMARCHY_FSTAB="$test_tmp/fstab" OMARCHY_LIMINE_DROPINS="$test_tmp/limine-entry-tool.d" \
  bash "$ROOT/bin/omarchy-mac-limine-cmdline"
grep -Eq "^KERNEL_CMDLINE\[default\]\+?=\".* $display quiet splash\"$" "$test_tmp/limine" ||
  fail "Limine's entry gets the display switches from the GRUB defaults" "$(cat "$test_tmp/limine")"
[[ $(grep -o 'apple_dart\.j713_d' "$test_tmp/limine" | wc -l) == 2 ]] || fail "Limine carries each switch once"
pass "the shared GRUB defaults carry the display switches into Limine"

# An Omarchy image's first boot: the defaults finalize-root writes.
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0"\n' >"$test_tmp/grub"
run
grep -Fxq "GRUB_CMDLINE_LINUX=\"zswap.enabled=0 rootfstype=btrfs rootflags=x-systemd.device-timeout=0 $display\"" "$test_tmp/grub" ||
  fail "an image's first boot on an M4 gets the switches with the root wait" "$(cat "$test_tmp/grub")"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX=""\n' >"$test_tmp/grub"
MKINITCPIO_CONF=$busybox_conf run
grep -Fxq "GRUB_CMDLINE_LINUX=\"$display\"" "$test_tmp/grub" || fail "a busybox M4 gets the switches alone" "$(cat "$test_tmp/grub")"
pass "an image's first boot and a busybox initramfs get the switches"

for choice in apple_dart.j713_dcp=0 apple_dart.j713_display=0 apple-dart.j713-dcp=0 apple_dart.j713_display apple_dart.j713_dcp=1; do
  for variable in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
    if [[ $variable == "GRUB_CMDLINE_LINUX" ]]; then
      printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rootflags=subvol=@,x-systemd.device-timeout=0 %s"\n' "$choice" >"$test_tmp/grub"
    else
      printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rootflags=subvol=@,x-systemd.device-timeout=0"\n' >"$test_tmp/grub"
      printf '%s="quiet %s"\n' "$variable" "$choice" >>"$test_tmp/grub"
    fi
    cp "$test_tmp/grub" "$test_tmp/owner"
    run
    cmp -s "$test_tmp/grub" "$test_tmp/owner" || fail "the owner's $choice in $variable keeps both switches as they are" "$(cat "$test_tmp/grub")"
  done
done
pass "an owner's own value for either switch, in either variable, is kept and nothing is added"

no_display() {
  printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rootflags=subvol=@,x-systemd.device-timeout=0"\n' >"$test_tmp/grub"
  cp "$test_tmp/grub" "$test_tmp/before"
  run
  cmp -s "$test_tmp/grub" "$test_tmp/before" || fail "$1" "$(cat "$test_tmp/grub")"
}
rm "$OMARCHY_APPLE_DART_PARAMETERS/j713_display"
no_display "a kernel with only one switch gets neither"
rm -r "$OMARCHY_APPLE_DART_PARAMETERS"
no_display "a kernel without the switches gets nothing"
mkdir -p "$OMARCHY_APPLE_DART_PARAMETERS"
touch "$OMARCHY_APPLE_DART_PARAMETERS/j713_dcp" "$OMARCHY_APPLE_DART_PARAMETERS/j713_display"
printf 'apple,j613\0apple,t8122\0apple,arm-platform\0' >"$test_tmp/compatible"
no_display "an M3 Air gets nothing"
printf 'apple,j604\0apple,t8132x\0' >"$test_tmp/compatible"
no_display "only the whole compatible apple,t8132 counts"
rm "$test_tmp/compatible"
no_display "a Mac without a readable device tree gets nothing"
printf 'apple,j604\0apple,t8132\0apple,arm-platform\0' >"$test_tmp/compatible"
TEST_CHROOT=0 no_display "a chroot gets nothing"
OMARCHY_SYSTEMD_RUN="$test_tmp/no-systemd" no_display "a root without a booted systemd gets nothing"
OMARCHY_MAC_IMAGE_BUILD=1 no_display "an image build gets nothing"
pass "nothing changes without both switches in the running kernel, off an M4, or outside the booted Mac"
