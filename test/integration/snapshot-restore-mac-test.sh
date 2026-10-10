#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
source "$BOOT/test/fixtures/limine-mac.sh"

require_platform_fixtures "omarchy-snapshot restore on platform fixtures"
require_command gzip
require_command b2sum

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The host's own limine-snapper-sync, snapper and Omarchy commands stay out of
# reach: a restore that finds the real limine-snapper-restore runs it, and it
# waits on the host's system. Everything else on PATH, first match wins.
host=$tmp/host
mkdir -p "$host"
IFS=: read -ra host_path <<<"$PATH"
for (( i = ${#host_path[@]} - 1; i >= 0; i-- )); do
  dir=${host_path[i]}
  [[ $dir == /* && -d $dir ]] || continue
  shopt -s nullglob
  commands=("$dir"/*)
  shopt -u nullglob
  (( ${#commands[@]} == 0 )) || ln -sf "${commands[@]}" "$host/"
done
rm -f "$host"/limine-* "$host"/snapper* "$host"/omarchy-*
export PATH=$host

# A restore that still reaches something it should not fails, never hangs.
guarded() {
  timeout --kill-after=5 60 "$@"
}

for platform in aarch64-apple x86; do
  fake_platform "$tmp/$platform" "$platform"
done
limine_mac_init "$tmp/mac"

# sudo records itself and snapper is a stub; the omarchy-mac-boot commands are
# the package's own, with omarchy-mac-limine-active recorded.
common=$tmp/common
mkdir -p "$common" "$tmp/limine" "$tmp/hooks/pre.d" "$tmp/hooks/post.d" "$tmp/no-hooks/pre.d" "$tmp/no-hooks/post.d"
cat >"$common/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$CALLS"
exec "$@"
SH
printf '#!/bin/bash\nexit 0\n' >"$common/snapper"
printf '#!/bin/bash\nexit 0\n' >"$common/limine-update"
cat >"$common/omarchy-mac-limine-active" <<SH
#!/bin/bash
echo omarchy-mac-limine-active >>"\$CALLS"
exec bash $(printf '%q' "$BOOT/bin/omarchy-mac-limine-active")
SH
# limine-snapper-restore as root runs limine-snapper-sync --restore: every pre
# hook first, stopping at one that exits 100 or more; then the restore, which
# makes @ the booted snapshot or, picked from its own list, LSS_PICK, keeps the
# previous root as backup snapshot 13 and puts the picked root's kernel back in
# the ESP's UKI; then the post hooks, where one that exits 100 or more keeps it
# from offering the reboot.
cat >"$tmp/limine/limine-snapper-restore" <<'SH'
#!/bin/bash
export HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE="--restore --no-mutex"
run_hooks() {
  local hook rc
  for hook in "$HOOKS_DIR/$1.d"/*; do
    [[ -f $hook && -x $hook ]] || continue
    rc=0
    "$hook" || rc=$?
    (( rc == 0 )) && continue
    if (( rc >= 100 )); then
      echo "ERROR: $1 hook failed (fatal, exit code $rc): $hook" >&2
      return 1
    fi
    echo "WARNING: $1 hook failed (exit code $rc): $hook" >&2
  done
}
if ! run_hooks pre; then
  echo "Aborting limine-snapper-restore: pre hook failed"
  exit 2
fi
rm -rf "$OMARCHY_SNAPSHOT_TOP/@"
cp -a "${LSS_PICK:-$BOOTED}" "$OMARCHY_SNAPSHOT_TOP/@"
mkdir -p "$OMARCHY_SNAPSHOT_TOP/@/.snapshots/13"
echo '<snapshot><num>13</num></snapshot>' >"$OMARCHY_SNAPSHOT_TOP/@/.snapshots/13/info.xml"
for image in "$OMARCHY_SNAPSHOT_TOP"/@/usr/lib/modules/*/vmlinuz; do
  { cat "$image"; printf 'initrd\n'; } >"$MAC_UKI"
done
echo restored >"$OMARCHY_SNAPSHOT_RESTORE_LOCK"
echo restored >>"$CALLS"
if run_hooks post; then
  echo "Restore complete. Reboot now? [Y/n]:"
else
  echo "Restore complete. Please reboot manually."
fi
SH
chmod +x "$common"/* "$tmp/limine"/*
ln -s "$BOOT/bin/omarchy-mac-snapshot-check" "$tmp/hooks/pre.d/04-omarchy-mac-snapshot-check"
ln -s "$BOOT/bin/omarchy-mac-snapshot-check" "$tmp/hooks/post.d/99-omarchy-mac-snapshot-check"

# Snapshot trees for the restore to put back: $2 is the kernel image, the rest
# of the boot files are the fixture's.
snapshot_root_tree() {
  local tree=$1 modules
  rm -rf "$tree"
  mkdir -p "$tree/.snapshots/12"
  cp -a "$mac_root/usr" "$mac_root/etc" "$mac_root/var" "$tree/"
  install -m755 /dev/null "$tree/usr/bin/limine-update"
  modules=$tree/usr/lib/modules/$mac_kver
  printf '%s\n' "$2" >"$modules/vmlinuz"
  printf 'linux-aurora\n' >"$modules/pkgbase"
  : >"$modules/modules.dep"
}

snapshot_cmdline='root=UUID=r rw rootflags=subvol=/@/.snapshots/7/snapshot quiet'
live_cmdline='root=UUID=r rw rootflags=subvol=@ quiet'

# omarchy-snapshot restore on platform $1; $2 is "limine" when limine-snapper-sync
# is installed, and $3 the directory of hooks it runs. TEST_CMDLINE is the
# kernel command line, a boot of snapshot 7 unless set.
run_restore() {
  local platform=$1 limine=$2 hooks=${3:-$tmp/no-hooks} path
  path=$tmp/$platform/bin:$common
  [[ $limine != limine ]] || path+=:$tmp/limine
  path+=:$ROOT/bin:$BOOT/bin
  printf '%s\n' "${TEST_CMDLINE:-$snapshot_cmdline}" >"$tmp/cmdline"
  mkdir -p "$tmp/top"
  [[ -d $tmp/booted ]] || snapshot_root_tree "$tmp/booted" "linux-aurora kernel $mac_kver"
  : >"$tmp/calls"
  set +e
  (
    eval "$(limine_mac_env "$path")"
    export PATH="$path:$PATH"
    export CALLS="$tmp/calls" HOOKS_DIR="$hooks" OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_CMDLINE="$tmp/cmdline"
    export OMARCHY_LIMINE_GATE="$mac_root/var/lib/omarchy/limine.enabled" OMARCHY_LIMINE_DEFAULT="$mac_root/etc/default/limine"
    export OMARCHY_BOOT_DIR="$mac_root/boot" BOOTED="$tmp/booted"
    export OMARCHY_SNAPSHOT_TOP="$tmp/top" OMARCHY_SNAPSHOT_RESTORE_LOCK="$tmp/restore.lock" OMARCHY_SNAPSHOT_CHECK_STATE="$tmp/state"
    export MAC_UKI="$mac_esp/EFI/Linux/omarchy_linux-aurora.efi"
    guarded bash "$ROOT/bin/omarchy-snapshot" restore </dev/null
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
  set -e
  (( status != 124 && status != 137 )) || fail "the restore finishes within a minute" "$(cat "$tmp/out" "$tmp/err")"
}

# x86: the package's hooks are installed but let the restore through untouched,
# and nothing asks whether a Mac boots Limine.
limine_mac
run_restore x86 limine "$tmp/hooks"
(( status == 0 )) && [[ $(cat "$tmp/calls") == $'sudo limine-snapper-restore\nrestored' ]] && grep -Fq "Reboot now" "$tmp/out" ||
  fail "x86 restores with limine-snapper-restore through the Mac hooks" "$(cat "$tmp/calls" "$tmp/out" "$tmp/err")"
pass "x86 restores as before, without any Mac check"

# A snapshot boot came from Limine's menu, even of a snapshot from before
# Limine, when the Mac booted GRUB: Limine's restore hook says why it can't.
limine_mac
rm "$mac_root/var/lib/omarchy/limine.enabled"
run_restore aarch64-apple limine "$tmp/hooks"
(( status != 0 )) && grep -Fxq 'sudo limine-snapper-restore' "$tmp/calls" && ! grep -Fxq restored "$tmp/calls" &&
  grep -Fq "Snapshot 7 was taken before Limine was activated on this Mac" "$tmp/err" ||
  fail "a boot of a snapshot from before Limine is refused by Limine's restore hook" "$(cat "$tmp/calls" "$tmp/err")"
pass "a boot of a snapshot from before Limine is told why it cannot be restored"

# A Limine Mac booted into snapshot 7 from the menu: the x86 restore, which the
# package's pre hook lets through when the snapshot matches the boot files.
limine_mac
run_restore aarch64-apple limine "$tmp/hooks"
(( status == 0 )) && grep -Fxq 'sudo limine-snapper-restore' "$tmp/calls" && grep -Fxq restored "$tmp/calls" ||
  fail "a Limine Mac restores a matching snapshot with limine-snapper-restore" "$(cat "$tmp/calls" "$tmp/out" "$tmp/err")"
grep -Fq "Snapshot 7 matches this Mac's boot files" "$tmp/out" || fail "the restore says the snapshot was checked" "$(cat "$tmp/out")"
pass "a Limine Mac restores a snapshot that matches its boot files through limine-snapper-restore"

# The same, after a kernel update the snapshot predates.
limine_mac
printf 'linux-aurora kernel 6.18.0-aurora1-ARCH\n' >"$mac_root/boot/vmlinuz-linux-aurora"
run_restore aarch64-apple limine "$tmp/hooks"
(( status != 0 )) && ! grep -Fxq restored "$tmp/calls" ||
  fail "a snapshot from before a kernel update is not restored" "$(cat "$tmp/calls" "$tmp/err")"
grep -Fq "Snapshot 7 does not match this Mac's boot files, so it is not restored" "$tmp/err" &&
  grep -Fq "/boot/vmlinuz-linux-aurora is not the $mac_kver kernel linux-aurora installed" "$tmp/err" &&
  grep -Fq "A snapshot holds the root file system only" "$tmp/err" ||
  fail "the refusal says what differs and why" "$(cat "$tmp/err")"
pass "a Limine Mac refuses a snapshot from before a kernel update, and explains"

# Booted into snapshot 7, but another snapshot picked from limine-snapper-restore's
# own list: the pre hook checked 7, so the post hook checks what came back.
limine_mac
rm -rf "$tmp/state"
snapshot_root_tree "$tmp/picked" "linux-aurora kernel 6.16.0-aurora0-ARCH"
LSS_PICK=$tmp/picked run_restore aarch64-apple limine "$tmp/hooks"
grep -Fxq restored "$tmp/calls" && grep -Fq "Please reboot manually" "$tmp/out" && ! grep -Fq "Reboot now" "$tmp/out" ||
  fail "a mismatched snapshot picked from the list is not offered the reboot" "$(cat "$tmp/calls" "$tmp/out" "$tmp/err")"
grep -Fq "The restore put back a root this Mac's boot files do not match" "$tmp/err" &&
  grep -Fq "Do not reboot yet" "$tmp/err" && grep -Fq "pick snapshot 13, the backup this restore just made" "$tmp/err" ||
  fail "the post hook says what went wrong and how to undo it" "$(cat "$tmp/err")"
pass "a snapshot picked from limine-snapper-restore's list is checked after the restore"

# Undo it as the message says, from the same boot: the ESP's UKI now carries the
# refused root's kernel, which the pre hook's boot check would refuse.
LSS_PICK=$tmp/booted run_restore aarch64-apple limine "$tmp/hooks"
(( status == 0 )) && grep -Fq "Press l and pick snapshot 13, the backup that restore made." "$tmp/out" &&
  grep -Fq "Reboot now" "$tmp/out" && grep -Fq "The restored root matches this Mac's boot files" "$tmp/out" ||
  fail "the previous root is put back through the hooks and offered the reboot" "$(cat "$tmp/out" "$tmp/err")"
[[ ! -e $tmp/state/undo ]] || fail "putting the previous root back ends the undo"
pass "a refused restore is undone through the hooks, as the message says"

limine_mac
rm -rf "$tmp/state"
snapshot_root_tree "$tmp/picked" "linux-aurora kernel $mac_kver"
LSS_PICK=$tmp/picked run_restore aarch64-apple limine "$tmp/hooks"
(( status == 0 )) && grep -Fq "Reboot now" "$tmp/out" && grep -Fq "The restored root matches this Mac's boot files" "$tmp/out" ||
  fail "a matching snapshot picked from the list is restored and offered the reboot" "$(cat "$tmp/out" "$tmp/err")"
pass "a matching snapshot picked from limine-snapper-restore's list is restored"

# Omarchy's restore always runs limine-snapper-restore and has no subvolume
# swap, so the pre hook refuses a GRUB Mac without sending it back to one.
limine_mac
rm "$mac_root/var/lib/omarchy/limine.enabled"
TEST_CMDLINE=$live_cmdline run_restore aarch64-apple limine "$tmp/hooks"
(( status != 0 )) && ! grep -Fxq restored "$tmp/calls" && grep -Fq "This Mac boots GRUB" "$tmp/err" &&
  ! grep -Fq "omarchy-snapshot restore" "$tmp/err" ||
  fail "a GRUB Mac is refused and not sent back to omarchy-snapshot restore" "$(cat "$tmp/calls" "$tmp/err")"
pass "a Mac that boots GRUB is told limine-snapper-restore does not apply"
