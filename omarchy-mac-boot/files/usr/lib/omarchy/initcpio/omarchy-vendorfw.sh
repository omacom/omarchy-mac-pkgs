#!/usr/bin/sh
set -eu
extract=${OMARCHY_VENDORFW_EXTRACT:-/run/omarchy-vendorfw-extract}
record=${OMARCHY_VENDORFW_STAGED:-/run/omarchy-vendorfw-initrd.staged}
dst=${OMARCHY_VENDORFW_SYSROOT_DEST:-/sysroot/lib/firmware/vendor}
proc_mounts=${OMARCHY_VENDORFW_PROC_MOUNTS:-/proc/mounts}
vendorfw_dir=${OMARCHY_VENDORFW_DIR:-/vendorfw}

# Reuse the firmware already staged before cryptsetup instead of remounting
# the ESP, re-extracting firmware.cpio, and leaking /run/omarchy-vendorfw-extract.
if [ -e "$record" ]; then
    if [ -d "$extract" ] && grep -Fq " $extract " "$proc_mounts" 2>/dev/null &&
        grep -Fq " $vendorfw_dir " "$proc_mounts" 2>/dev/null; then
        mkdir -p "$dst"
        mount --bind "$extract" "$dst"
        umount "$vendorfw_dir"
        umount "$extract"
        rmdir "$extract" 2>/dev/null || true
        exit 0
    fi
    if [ -d "$vendorfw_dir" ]; then
        mkdir -p "$dst"
        mount -t tmpfs -o mode=0755 vendorfw "$dst"
        cp -a "$vendorfw_dir"/. "$dst"/
        if [ -d "$extract" ]; then
            if grep -Fq " $extract " "$proc_mounts" 2>/dev/null; then
                umount "$extract"
            fi
            rm -rf "$extract"
        fi
        exit 0
    fi
fi

dt=${OMARCHY_VENDORFW_DEVICE_TREE_ESP:-/proc/device-tree/chosen/asahi,efi-system-partition}
[ -e "$dt" ] || exit 0
esp=$(tr -d '\0' <"$dt")
[ -n "$esp" ] || exit 0
mnt=/run/omarchy-vendorfw-esp
mkdir -p "$mnt"
mount -o ro "PARTUUID=$esp" "$mnt"
if [ -f "$mnt/vendorfw/firmware.cpio" ]; then
    (cd / && cpio -i <"$mnt/vendorfw/firmware.cpio")
fi
umount "$mnt"
rmdir "$mnt" 2>/dev/null || true
[ -d "$vendorfw_dir" ] || exit 0
mkdir -p "$dst"
mount -t tmpfs -o mode=0755 vendorfw "$dst"
cp -a "$vendorfw_dir"/. "$dst"/
