#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# omarchy-vendorfw.sh reuses firmware staged by omarchy-vendorfw-initrd.sh
# before cryptsetup without remounting the ESP, re-extracting firmware.cpio,
# losing preloaded files, or leaking /run/omarchy-vendorfw-extract.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

late_sh=$ROOT/files/usr/lib/omarchy/initcpio/omarchy-vendorfw.sh
early_sh=$ROOT/files/usr/lib/omarchy/initcpio/omarchy-vendorfw-initrd.sh

grep -Fq 'cp -a' "$early_sh" || fail 'early helper preserves hardlinks with cp -a'
grep -Fq 'cp -a' "$late_sh" || fail 'late helper preserves hardlinks with cp -a'
grep -Fq 'mount --bind' "$late_sh" || fail 'late helper reuses staged tmpfs with mount --bind'
grep -Fq 'umount "$extract"' "$late_sh" || fail 'late helper unmounts staged tmpfs to avoid leaking it in /run'

# Case 1: staged + both extract and /vendorfw bind-mounted -> bind-mount into sysroot and unmount both.
calls=$work/calls
stub=$work/bin
mkdir -p "$stub" "$work/extract/apple" "$work/dst" "$work/vendorfw"
touch "$work/staged"
printf 'blob\n' >"$work/extract/apple/fw.bin"
printf 'omarchy-vendorfw-extract %s tmpfs rw 0 0\nomarchy-vendorfw-extract %s tmpfs rw 0 0\n' \
  "$work/extract" "$work/vendorfw" >"$work/mounts"

cat >"$stub/mount" <<SH
#!/bin/sh
printf 'mount %s\n' "\$*" >>"$calls"
exit 0
SH
cat >"$stub/umount" <<SH
#!/bin/sh
printf 'umount %s\n' "\$*" >>"$calls"
exit 0
SH
cat >"$stub/cpio" <<SH
#!/bin/sh
printf 'cpio %s\n' "\$*" >>"$calls"
exit 99
SH
chmod +x "$stub"/{mount,umount,cpio}

: >"$calls"
PATH="$stub:$PATH" \
  OMARCHY_VENDORFW_EXTRACT="$work/extract" \
  OMARCHY_VENDORFW_STAGED="$work/staged" \
  OMARCHY_VENDORFW_SYSROOT_DEST="$work/dst" \
  OMARCHY_VENDORFW_PROC_MOUNTS="$work/mounts" \
  OMARCHY_VENDORFW_DIR="$work/vendorfw" \
  sh "$late_sh"

grep -Fxq "mount --bind $work/extract $work/dst" "$calls" ||
  fail 'late helper bind-mounts staged extract onto sysroot destination' "$(cat "$calls")"
grep -Fxq "umount $work/vendorfw" "$calls" ||
  fail 'late helper unmounts /vendorfw bind mount before switch-root' "$(cat "$calls")"
grep -Fxq "umount $work/extract" "$calls" ||
  fail 'late helper unmounts staged extract mountpoint' "$(cat "$calls")"
if grep -q '^cpio ' "$calls"; then
  fail 'late helper must not re-run cpio when early helper already staged firmware' "$(cat "$calls")"
fi
pass 'late helper reuses mounted staged tmpfs via bind-mount and cleans up'

# Case 2: staged + early helper merged into preloaded /vendorfw (not bind-mounted) -> copies merged /vendorfw with hardlinks intact.
work2=$work/case2
mkdir -p "$work2/extract/brcm" "$work2/vendorfw/keep" "$work2/vendorfw/brcm" "$work2/dst"
touch "$work2/staged"
printf 'omarchy-vendorfw-extract %s tmpfs rw 0 0\n' "$work2/extract" >"$work2/extract-only-mounts"
printf 'preloaded\n' >"$work2/vendorfw/keep/already-there.bin"
printf 'shared-firmware\n' >"$work2/vendorfw/brcm/a.bin"
ln "$work2/vendorfw/brcm/a.bin" "$work2/vendorfw/brcm/b.bin"

: >"$calls"
PATH="$stub:$PATH" \
  OMARCHY_VENDORFW_EXTRACT="$work2/extract" \
  OMARCHY_VENDORFW_STAGED="$work2/staged" \
  OMARCHY_VENDORFW_SYSROOT_DEST="$work2/dst" \
  OMARCHY_VENDORFW_PROC_MOUNTS="$work2/extract-only-mounts" \
  OMARCHY_VENDORFW_DIR="$work2/vendorfw" \
  sh "$late_sh"

[[ $(cat "$work2/dst/keep/already-there.bin") == preloaded ]] ||
  fail 'merged fallback preserves preloaded firmware from /vendorfw'
[[ -f $work2/dst/brcm/a.bin && -f $work2/dst/brcm/b.bin ]] ||
  fail 'merged fallback copies extracted firmware from /vendorfw'
inode_a=$(stat -c %i "$work2/dst/brcm/a.bin")
inode_b=$(stat -c %i "$work2/dst/brcm/b.bin")
[[ $inode_a == "$inode_b" ]] ||
  fail 'merged fallback preserves hardlinks' "inodes $inode_a vs $inode_b"
grep -Fxq "umount $work2/extract" "$calls" ||
  fail 'merged fallback unmounts leftover extract mountpoint if still mounted' "$(cat "$calls")"
[[ ! -e $work2/extract ]] ||
  fail 'merged fallback removes leftover extract directory'
if grep -q '^cpio ' "$calls"; then
  fail 'merged fallback must not re-run cpio when early helper already staged firmware' "$(cat "$calls")"
fi
pass 'merged fallback preserves preloaded files and hardlinks and cleans up leftover extract'
