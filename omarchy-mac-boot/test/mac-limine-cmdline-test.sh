#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

cmdline="$ROOT/bin/omarchy-mac-limine-cmdline"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

grub="$test_tmp/grub"
limine="$test_tmp/limine"
fstab="$test_tmp/fstab"
root_uuid=4f4d5801-524f-4f54-8000-000000000001
luks=1111aaaa-2222-bbbb-3333-cccc4444dddd

cat >"$grub" <<CONF
GRUB_CMDLINE_LINUX="rd.luks.name=$luks=root rd.luks.key=$luks=/omarchy/luks-key:UUID=boot rootflags=x-systemd.device-timeout=0"
GRUB_CMDLINE_LINUX_DEFAULT="zswap.enabled=0 rootfstype=btrfs rootflags=x-systemd.device-timeout=0 quiet splash root=/dev/wrong rw"
CONF
printf 'UUID=%s / btrfs subvol=@,x-systemd.growfs 0 0\nUUID=boot /boot ext4 defaults 0 2\n' "$root_uuid" >"$fstab"
cat >"$limine" <<'CONF'
ESP_PATH="/boot/efi"
TARGET_OS_NAME="Omarchy"
KERNEL_CMDLINE[default]=""
BOOT_ORDER="linux-aurora, *, Snapshots"
CONF

run() {
  OMARCHY_GRUB_DEFAULT="$grub" OMARCHY_LIMINE_DEFAULT="$limine" OMARCHY_FSTAB="$fstab" bash "$cmdline"
}

run || fail "omarchy-mac-limine-cmdline succeeds"
want="KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw rootflags=subvol=@,x-systemd.device-timeout=0 rd.luks.name=$luks=root rd.luks.key=$luks=/omarchy/luks-key:UUID=boot zswap.enabled=0 rootfstype=btrfs quiet splash\""
grep -Fxq "$want" "$limine" ||
  fail "the command line is root=UUID from fstab, rw, one merged rootflags with subvol=@, then GRUB's words without repeats" "$(cat "$limine")"
(( $(grep -c '^KERNEL_CMDLINE\[default\]' "$limine") == 1 )) || fail "exactly one KERNEL_CMDLINE[default] line"
grep -Fxq 'TARGET_OS_NAME="Omarchy"' "$limine" && grep -Fxq 'BOOT_ORDER="linux-aurora, *, Snapshots"' "$limine" ||
  fail "the other Limine keys are kept in place"
! grep -q 'root=/dev/wrong' "$limine" || fail "a root= in GRUB's variables is dropped in favour of the filesystem UUID"
pass "the Limine command line is derived from GRUB's defaults"

cp "$limine" "$test_tmp/before"
run || fail "second run succeeds"
cmp -s "$limine" "$test_tmp/before" || fail "a second run changes nothing"
pass "deriving the command line is idempotent"

# The rd.luks.key= drop of the owner's re-key reaches Limine on the next run.
sed -i.bak "s| rd.luks.key=[^ \"]*||" "$grub"
run || fail "run after re-key succeeds"
! grep -q 'rd.luks.key=' "$limine" || fail "rd.luks.key= leaves the Limine command line once GRUB's defaults drop it"
grep -q "rd.luks.name=$luks=root" "$limine" || fail "rd.luks.name= stays"
pass "GRUB's defaults stay the source of truth after the re-key"

# No UUID in fstab: the mounted root's.
printf '/dev/mapper/root / btrfs subvol=@ 0 0\n' >"$fstab"
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
[[ "$*" == "-no UUID /" ]] && echo mounted-root-uuid
SH
chmod +x "$stub_bin/findmnt"
PATH="$stub_bin:$PATH" run || fail "run with a device root row succeeds"
grep -q 'root=UUID=mounted-root-uuid ' "$limine" || fail "without a UUID in fstab the mounted root's UUID is used" "$(cat "$limine")"
pass "the mounted root is the fallback for the UUID"

# A snapshot boot: no fstab row, an overlay root, the UUID from the cmdline.
printf '# omarchy-mac-snapshot-overlay: UUID=x / btrfs subvol=@ 0 0\n' >"$fstab"
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/findmnt"
printf 'root=UUID=booted-root rw rootflags=subvol=/@/.snapshots/8/snapshot quiet\n' >"$test_tmp/cmdline"
OMARCHY_CMDLINE="$test_tmp/cmdline" PATH="$stub_bin:$PATH" run || fail "run in a snapshot boot succeeds"
grep -q 'root=UUID=booted-root ' "$limine" || fail "a snapshot boot takes the UUID from the kernel command line" "$(cat "$limine")"
pass "the booted root is the last fallback for the UUID"

# No UUID anywhere: the file keeps its line and the run fails.
cp "$limine" "$test_tmp/before"
OMARCHY_CMDLINE=/dev/null PATH="$stub_bin:$PATH" run 2>/dev/null && fail "an unknown root UUID fails the derivation"
cmp -s "$limine" "$test_tmp/before" || fail "an unknown root UUID changes nothing"
pass "no UUID, no change, a failure"

# Nothing to derive from: the file is left alone.
cp "$limine" "$test_tmp/before"
OMARCHY_GRUB_DEFAULT="$test_tmp/missing" OMARCHY_LIMINE_DEFAULT="$limine" OMARCHY_FSTAB="$fstab" bash "$cmdline" ||
  fail "a missing GRUB default file is not an error"
cmp -s "$limine" "$test_tmp/before" || fail "a missing GRUB default file changes nothing"
pass "no GRUB defaults, no change"

# The root filesystem decides the subvolume: ext4 takes no subvol= (the kernel
# refuses it and the boot stops in the emergency shell), btrfs its own.
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/findmnt"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$grub"
printf 'UUID=%s / ext4 rw,relatime 0 1\n' "$root_uuid" >"$fstab"
PATH="$stub_bin:$PATH" run || fail "run on an ext4 root succeeds"
grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw quiet splash\"" "$limine" ||
  fail "an ext4 root gets no rootflags" "$(cat "$limine")"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="rootflags=x-systemd.device-timeout=0 quiet"\n' >"$grub"
PATH="$stub_bin:$PATH" run || fail "run on an ext4 root with GRUB rootflags succeeds"
grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw rootflags=x-systemd.device-timeout=0 quiet\"" "$limine" ||
  fail "an ext4 root keeps GRUB's rootflags without subvol=" "$(cat "$limine")"
printf 'UUID=%s / btrfs rw,noatime,subvol=/@root 0 0\n' "$root_uuid" >"$fstab"
PATH="$stub_bin:$PATH" run || fail "run on a btrfs root with its own subvolume succeeds"
grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw rootflags=subvol=@root,x-systemd.device-timeout=0 quiet\"" "$limine" ||
  fail "a btrfs root boots the subvolume fstab mounts" "$(cat "$limine")"
printf 'UUID=%s / btrfs rw,noatime 0 0\n' "$root_uuid" >"$fstab"
PATH="$stub_bin:$PATH" run || fail "run on a btrfs root with no subvolume succeeds"
grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw rootflags=x-systemd.device-timeout=0 quiet\"" "$limine" ||
  fail "a btrfs root mounted without a subvolume boots its default one" "$(cat "$limine")"
# No fstab row: the mounted root.
printf '# nothing\n' >"$fstab"
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  "-no UUID /") echo mounted-root-uuid ;;
  "-no FSTYPE,OPTIONS /") echo "ext4 rw,relatime" ;;
  *) exit 1 ;;
esac
SH
PATH="$stub_bin:$PATH" run || fail "run on a mounted ext4 root succeeds"
grep -Fxq 'KERNEL_CMDLINE[default]+="root=UUID=mounted-root-uuid rw rootflags=x-systemd.device-timeout=0 quiet"' "$limine" ||
  fail "without an fstab row the mounted root's filesystem decides" "$(cat "$limine")"
pass "rootflags carry the subvolume only a btrfs root mounts"

# A btrfs root fstab selects by subvolid= keeps that selector; subvol=/ is the
# top level.
printf 'UUID=%s / btrfs rw,subvolid=256 0 0\n' "$root_uuid" >"$fstab"
PATH="$stub_bin:$PATH" run || fail "run on a btrfs root selected by subvolid succeeds"
grep -Fq 'rootflags=subvolid=256,x-systemd.device-timeout=0 ' "$limine" || fail "subvolid= is kept" "$(cat "$limine")"
printf 'UUID=%s / btrfs rw,subvol=/ 0 0\n' "$root_uuid" >"$fstab"
PATH="$stub_bin:$PATH" run || fail "run on a btrfs top-level root succeeds"
grep -Fq 'rootflags=subvol=/,x-systemd.device-timeout=0 ' "$limine" || fail "subvol=/ stays the top level" "$(cat "$limine")"
pass "subvolid= and the top-level subvolume are kept"

# A command line that cannot be written stops limine-entry-tool's rebuild: its
# hook runner aborts only on 100 and above.
cp "$limine" "$test_tmp/before"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash changed"\n' >"$grub"
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/install"
chmod +x "$stub_bin/install"
status=0
PATH="$stub_bin:$PATH" run 2>/dev/null || status=$?
(( status >= 100 )) || fail "a failed write aborts the rebuild (status $status)"
cmp -s "$limine" "$test_tmp/before" || fail "a failed write leaves the defaults unchanged"
rm "$stub_bin/install"
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/mktemp"
chmod +x "$stub_bin/mktemp"
status=0
PATH="$stub_bin:$PATH" run 2>/dev/null || status=$?
(( status >= 100 )) || fail "a failed staging file aborts the rebuild (status $status)"
rm "$stub_bin/mktemp"
pass "write failures abort the UKI rebuild"

# A Mac set up before += keeps a plain = line; the next run rewrites it, so
# drop-ins reach its entries from the next UKI rebuild on.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' >"$grub"
printf 'UUID=%s / ext4 rw 0 1\n' "$root_uuid" >"$fstab"
printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID=old rw quiet"\n' >"$limine"
run || fail "the run over an old = line succeeds"
grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw quiet\"" "$limine" &&
  ! grep -q '^KERNEL_CMDLINE\[default\]=' "$limine" || fail "an old = line becomes +=" "$(cat "$limine")"
printf 'ESP_PATH="/boot/efi"\n  KERNEL_CMDLINE[default]="root=UUID=old rw quiet"\n' >"$limine"
run || fail "the run over an indented = line succeeds"
[[ $(grep -c 'KERNEL_CMDLINE\[default\]' "$limine") == 1 ]] && ! grep -q 'root=UUID=old' "$limine" ||
  fail "an indented = line is replaced, not left beside the new one" "$(cat "$limine")"
# The helper owns the file's command lines, so an owner's own += line goes too;
# customisations belong in /etc/limine-entry-tool.d/.
printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]+="root=UUID=old rw quiet"\n  KERNEL_CMDLINE[default]+=" custom=1"\n' >"$limine"
run || fail "the run over an indented += line succeeds"
[[ $(grep -c 'KERNEL_CMDLINE\[default\]' "$limine") == 1 ]] && ! grep -q 'custom=1' "$limine" &&
  grep -Fxq "KERNEL_CMDLINE[default]+=\"root=UUID=$root_uuid rw quiet\"" "$limine" ||
  fail "an indented += line is removed with the rest" "$(cat "$limine")"
pass "an existing = line is rewritten with +=, and the helper's line is the only one"

# limine-entry-tool loads /etc/limine-entry-tool.d/*.conf before
# /etc/default/limine, so only += keeps what a drop-in appended. Runs the real
# tool in a user namespace with stand-ins bound over its config paths.
if command -v limine-entry-tool >/dev/null && unshare -rm true 2>/dev/null &&
  [[ -d /etc/limine-entry-tool.d && -f /etc/default/limine ]]; then
  stand_in=$test_tmp/entry-tool
  mkdir -p "$stand_in/d" "$stand_in/esp" "$stand_in/empty-dir"
  : >"$stand_in/empty-file"
  printf 'KERNEL_CMDLINE[default]+=" initramfs_async=0"\nKERNEL_CMDLINE[default]+=" systemd.tty.term.console=dumb"\n' \
    >"$stand_in/d/10-defaults.conf"
  printf 'ESP_PATH="%s"\n' "$stand_in/esp" >"$limine"
  run || fail "the run for the entry tool succeeds"
  # shellcheck disable=SC2016 # expanded by the namespace's shell
  result=$(unshare -rm bash -c '
    mount --bind "$1/d" /etc/limine-entry-tool.d && mount --bind "$2" /etc/default/limine || exit 1
    [[ ! -f /etc/limine-entry-tool.conf ]] || mount --bind "$1/empty-file" /etc/limine-entry-tool.conf || exit 1
    [[ ! -d /usr/share/limine-entry-tool.d ]] || mount --bind "$1/empty-dir" /usr/share/limine-entry-tool.d || exit 1
    limine-entry-tool --get-cmdline linux-aurora --no-mutex --no-hooks | tail -n 1' _ "$stand_in" "$limine") ||
    fail "limine-entry-tool reads the command line"
  [[ $result == "root=UUID=$root_uuid rw quiet "* && " $result " == *" initramfs_async=0 "* &&
    " $result " == *" systemd.tty.term.console=dumb "* ]] ||
    fail "the drop-in's words follow the derived line in limine-entry-tool's command line" "$result"
  pass "limine-entry-tool appends the drop-ins' words to the derived command line"
else
  printf 'skip - %s\n' "limine-entry-tool, a user namespace or its config paths are unavailable; its command line is not checked here"
fi
