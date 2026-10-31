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
printf 'PRESETS=(default)\nALL_config=%s\n' "$busybox_conf" >"$OMARCHY_MKINITCPIO_PRESET_DIR/linux-asahi.preset"
MKINITCPIO_CONF="$test_tmp/stock.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0"' "$test_tmp/grub" || fail "the preset's configuration, without drop-ins, decides" "$(cat "$test_tmp/grub")"
rm -rf "$OMARCHY_MKINITCPIO_CONF_DIR" "$OMARCHY_MKINITCPIO_PRESET_DIR"
MKINITCPIO_CONF="$test_tmp/missing.conf" run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootflags=x-systemd.device-timeout=0"' "$test_tmp/grub" ||
  fail "an unreadable configuration keeps the wait, as every image boots systemd" "$(cat "$test_tmp/grub")"
pass "the initramfs kind comes from the preset, mkinitcpio.conf and its drop-ins in mkinitcpio's order"

# Aurora uses host mixed-page support; Asahi's muvm Steam path does not.
cat >"$test_tmp/bin/omarchy-mac-kernel" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_KERNEL:-linux-aurora}"
STUB
chmod +x "$test_tmp/bin/omarchy-mac-kernel"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$test_tmp/grub"
if TEST_UPDATE_FAILURE=7 run; then fail "failed Aurora boot rebuild is reported"; fi
[[ -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "Aurora rebuild failure stays pending"
grep -Fxq 'GRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@,x-systemd.device-timeout=0 user4k=on"' "$test_tmp/grub" ||
  fail "Aurora enables user4k without losing root or encryption flags"
TEST_NOT_LIMINE=0 run
[[ ! -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "successful Aurora retry clears pending state"
[[ $(tail -n 1 "$TEST_CALLS") == omarchy-mac-boot-update ]] || fail "Aurora retries the active Limine rebuild"
cp "$test_tmp/grub" "$test_tmp/aurora-configured"
calls=$(wc -l <"$TEST_CALLS")
run
cmp -s "$test_tmp/grub" "$test_tmp/aurora-configured" || fail "Aurora defaults are idempotent"
[[ $(wc -l <"$TEST_CALLS") == "$calls" ]] || fail "Aurora does not rebuild again when configured"
pass "Aurora enables user4k for both loaders with retry and idempotence"

printf 'UUID=test-root / btrfs subvol=@ 0 0\n' >"$test_tmp/fstab"
printf 'KERNEL_CMDLINE[default]=""\n' >"$test_tmp/limine"
# No host limine-entry-tool drop-ins, and either assignment form the helper writes.
mkdir -p "$test_tmp/limine-entry-tool.d"
OMARCHY_LIMINE_DEFAULT="$test_tmp/limine" OMARCHY_FSTAB="$test_tmp/fstab" OMARCHY_LIMINE_DROPINS="$test_tmp/limine-entry-tool.d" \
  bash "$ROOT/bin/omarchy-mac-limine-cmdline"
grep -Exq 'KERNEL_CMDLINE\[default\]\+?="root=UUID=test-root rw rootflags=subvol=@,x-systemd.device-timeout=0 rd\.luks\.uuid=luks-id user4k=on quiet splash"' "$test_tmp/limine" ||
  fail "Limine receives user4k and the existing root/encryption options" "$(cat "$test_tmp/limine")"
[[ $(grep -o 'user4k=' "$test_tmp/limine" | wc -l) == 1 ]] || fail "Limine carries user4k once"
pass "the shared GRUB defaults carry user4k into Limine"

# An Omarchy Mac image's first boot: the defaults finalize-root writes.
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0"\n' >"$test_tmp/grub"
TEST_NOT_LIMINE=0 run
grep -Fxq 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs rootflags=x-systemd.device-timeout=0 user4k=on"' "$test_tmp/grub" ||
  fail "an image's first boot gets user4k with the root wait" "$(cat "$test_tmp/grub")"
TEST_NOT_LIMINE=0 run
[[ $(grep -o 'user4k=' "$test_tmp/grub" | wc -l) == 1 ]] || fail "a second setup-boot does not repeat user4k"
pass "an image's first boot gets user4k once"

for choice in off on 0 1; do
  for variable in GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT; do
    printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rootflags=subvol=@,x-systemd.device-timeout=0"\n' >"$test_tmp/grub"
    printf '%s="quiet user4k=%s"\n' "$variable" "$choice" >>"$test_tmp/grub"
    run
    grep -q "user4k=$choice" "$test_tmp/grub" || fail "explicit user4k=$choice survives in $variable"
    [[ $(grep -o 'user4k=' "$test_tmp/grub" | wc -l) == 1 ]] || fail "an explicit user4k choice is not duplicated"
  done
done
pass "explicit user4k choices in either GRUB variable are preserved"

printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX="rootflags=subvol=@,x-systemd.device-timeout=0"\n' >"$test_tmp/grub"
TEST_KERNEL=linux-asahi run
! grep -q 'user4k=' "$test_tmp/grub" || fail "Asahi keeps its existing host page policy"
TEST_KERNEL=unknown run
! grep -q 'user4k=' "$test_tmp/grub" || fail "an unknown kernel does not acquire Aurora's policy"
printf 'GRUB_VIDEO_BACKEND="efi_gop"\nGRUB_CMDLINE_LINUX=""\n' >"$test_tmp/grub"
MKINITCPIO_CONF=$busybox_conf run
grep -Fxq 'GRUB_CMDLINE_LINUX="user4k=on"' "$test_tmp/grub" || fail "busybox Aurora gets user4k without the systemd root wait"
pass "user4k is Aurora-specific and works with a busybox initramfs"
