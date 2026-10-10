#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

require_command gzip
require_command realpath
require_command locale

check="$ROOT/bin/omarchy-apple-silicon-boot-check"
grep -Fq '# omarchy:hidden=true' "$check" || fail "the boot check is hidden from command listings"
! grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?(update-m1n1|/usr/bin/update-m1n1|"?\$script"?)([[:space:];]|$)' "$check" ||
  fail "the boot check never runs update-m1n1"
! grep -Eq 'reboot-blocked' "$check" || fail "the boot check does not write the reboot-block marker"
pass "the boot check is hidden, never runs update-m1n1 and does not write the reboot-block marker"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
root="$test_tmp/root"
calls="$test_tmp/calls"
mounts="$test_tmp/mounts"
esp="$root/boot/efi"
esp_device="$test_tmp/esp-device"
existing="$test_tmp/existing-esp"
partuuid=5f2b0c3e-0002
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo:%s\n' "$*" >>"$TEST_CALLS"
exec "$@"
SH
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
case "$*" in
  -Qq) cat "$TEST_FILES/installed" ;;
  "-Qlq "*) [[ -f $TEST_FILES/$2 ]] && cat "$TEST_FILES/$2" ;;
  "-Qkk "*)
    # pacman prints warnings on stderr and the summary on stdout.
    [[ ${LC_ALL:-} == C ]] || { echo "pacman -Qkk without LC_ALL=C" >&2; exit 3; }
    # A fresh image has no sync databases, and pacman says so for each repo.
    if [[ -n ${TEST_QKK_NODB:-} ]]; then
      for repo in core extra alarm; do
        printf "warning: database file for '%s' does not exist (use '-Sy' to download)\n" "$repo" >&2
      done
    fi
    case ${TEST_QKK_FAIL:-} in
      "$2")
        printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/vmlinuz (Size mismatch)\n' "$2" >&2
        printf '%s: 2 total files, 1 altered files\n' "$2"
        exit 1
        ;;
      "$2:modules-size")
        printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (Size mismatch)\n' "$2" >&2
        printf '%s: 2 total files, 1 altered files\n' "$2"
        exit 1
        ;;
      "$2:depmod-size")
        printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (Modification time mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (Size mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (SHA256 checksum mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.alias (Modification time mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.alias (Size mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.alias (SHA256 checksum mismatch)\n' "$2" "$2" "$2" "$2" "$2" "$2" >&2
        printf '%s: 2353 total files, 2 altered files\n' "$2"
        exit 1
        ;;
      "$2:builtin-size")
        printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.builtin (Size mismatch)\n' "$2" >&2
        printf '%s: 2 total files, 1 altered files\n' "$2"
        exit 1
        ;;
      "$2:missing")
        printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (No such file or directory)\n' "$2" >&2
        printf '%s: 2 total files, 1 altered files\n' "$2"
        exit 1
        ;;
      "$2:silent") exit 1 ;;
    esac
    if [[ ${TEST_QKK_DEPMOD:-} == "$2" ]]; then
      printf 'warning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.dep (Modification time mismatch)\nwarning: %s: /usr/lib/modules/6.17.0-aurora1-ARCH/modules.alias.bin (Modification time mismatch)\n' "$2" "$2" >&2
      printf '%s: 2353 total files, 2 altered files\n' "$2"
      exit 1
    fi
    printf '%s: 2 total files, 0 altered files\n' "$2"
    ;;
  "-Qoq "*)
    owner=$(awk -v path="$2" '$1 == path { print $2 }' "$TEST_FILES/owners" 2>/dev/null)
    [[ -n $owner ]] || exit 1
    echo "$owner"
    ;;
  "-Q "*)
    [[ -f $TEST_FILES/version-$2 ]] || exit 1
    echo "$2 $(cat "$TEST_FILES/version-$2")"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
if [[ "$1" == "-a" && -f "$2" ]]; then
  cat "${TEST_INITRAMFS_ANALYZE:-$TEST_INITRAMFS_LIST.analyze}"
  exit 0
fi
[[ "$1" == "-l" && -f "$2" ]] || exit 1
cat "$TEST_INITRAMFS_LIST"
SH
# mount copies what it would mount and remembers whether that mount is
# read-only. A read-only mount of a device that is already mounted is refused,
# as the kernel refuses it; a bind can be made to come up writable.
cat >"$stub_bin/mount" <<'SH'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_CALLS"
options="" bind=0 positional=()
while (($#)); do
  case "$1" in
    -o) options=$2; shift 2 ;;
    --bind) bind=1; shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
target=${positional[-1]}
if [[ ,$options, == *,remount,* ]]; then
  [[ ${TEST_REMOUNT_FAILS:-0} != 1 ]] || exit 32
  sed -i "\|^$target |d" "$TEST_MOUNTS"
  echo "$target ro" >>"$TEST_MOUNTS"
  exit 0
fi
state=rw
[[ ,$options, != *,ro,* ]] || state=ro
if (( bind )); then
  source=${positional[0]}
  [[ ${TEST_BIND_COMES_UP_RW:-0} != 1 ]] || state=rw
else
  [[ ${positional[0]} == "PARTUUID=$TEST_PARTUUID" && -d $TEST_ESP_DEVICE ]] || exit 32
  if [[ -n ${TEST_EXISTING_MOUNT:-} || ${TEST_RO_REFUSED:-0} == 1 ]]; then
    echo "mount: $target: ${positional[0]} already mounted" >&2
    exit 32
  fi
  source=$TEST_ESP_DEVICE
fi
cp -a "$source/." "$target/"
echo "$target $state" >>"$TEST_MOUNTS"
SH
cat >"$stub_bin/umount" <<'SH'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_CALLS"
find "$1" -mindepth 1 -delete
sed -i "\|^$1 |d" "$TEST_MOUNTS"
SH
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  "-n -o VFS-OPTIONS --mountpoint "*)
    state=$(awk -v target="${@: -1}" '$1 == target { print $2 }' "$TEST_MOUNTS")
    [[ -n $state ]] || exit 1
    echo "$state,relatime"
    ;;
  "-n -r -o TARGET,FSROOT --source PARTUUID=$TEST_PARTUUID")
    [[ -n ${TEST_EXISTING_MOUNT:-} ]] || exit 1
    echo "$TEST_EXISTING_MOUNT /"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$stub_bin/lsblk" <<'SH'
#!/bin/bash
case "$*" in
  "-nsrpo NAME,FSTYPE "*) [[ -z ${TEST_LSBLK_CHAIN:-} ]] || printf '%b' "$TEST_LSBLK_CHAIN" ;;
  "-ndo UUID "*) [[ -z ${TEST_LUKS_UUID:-} ]] || echo "$TEST_LUKS_UUID" ;;
esac
exit 0
SH
# The dtc tools on the fixture's device trees (magic, size, then a text body):
# fdtoverlay appends "overlay NAME" to the body, dtc prints or accepts it, and
# no fixture overlay names skip-if-compatible. They live in the fixture root's
# /usr/bin, where the check and update-m1n1 look first with a root set; dtc
# reports the version in the dtc-version file beside it.
tools_src="$test_tmp/dtc-tools"
mkdir -p "$tools_src"
cat >"$tools_src/fdtoverlay" <<'SH'
#!/bin/bash
[[ $1 == -i && $3 == -o ]] || exit 1
# An overlay whose whole content is "overlay FAIL" does not apply, the way a
# real overlay fdtoverlay cannot merge does not.
if grep -q '^overlay FAIL$' "$5" 2>/dev/null; then exit 1; fi
body="$(tail -c +9 "$2")"$'\n'"overlay ${5##*/}"$'\n'
size=$(( 8 + ${#body} ))
{
  printf '\xd0\x0d\xfe\xed'
  printf "$(printf '\\x%02x' $(( size >> 24 & 255 )) $(( size >> 16 & 255 )) $(( size >> 8 & 255 )) $(( size & 255 )))"
  printf '%s' "$body"
} >"$4"
SH
cat >"$tools_src/dtc" <<'SH'
#!/bin/bash
[[ $1 != --version ]] || { echo "Version: DTC v$(cat "${0%/*}/dtc-version")"; exit 0; }
file=${!#}
[[ $(od -An -tx1 -N4 "$file" | tr -d ' \n') == d00dfeed ]] || exit 1
[[ " $* " != *" -O dts "* ]] || tail -c +9 "$file"
SH
cat >"$tools_src/fdtget" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin"/* "$tools_src"/*

# Puts the dtc tools, at dtc VERSION, in the fixture root.
dtc_tools() {
  mkdir -p "$root/usr/bin"
  cp "$tools_src"/* "$root/usr/bin/"
  printf '%s\n' "$1" >"$root/usr/bin/dtc-version"
}

# update-m1n1 as asahi-scripts 20260127.1 ships it, with the DTBS default ALARM adds.
write_update_m1n1() {
  mkdir -p "$root/usr/bin"
  cat >"$root/usr/bin/update-m1n1" <<'SH'
#!/bin/sh
# SPDX-License-Identifier: MIT

set -e

# The matrix runs this script against a fixture root: device tree and boot
# paths resolve there, the target does not.
cat() {
    for p in "$@"; do
        case $p in
            "$UPDATE_M1N1_TEST_ROOT"/* | "$UPDATE_M1N1_TEST_ROOT") ;;
            /usr/lib/* | /lib/* | /etc/*) p="$UPDATE_M1N1_TEST_ROOT$p" ;;
        esac
        command cat -- "$p"
    done
}

[ -e /etc/default/update-m1n1 ] && . /etc/default/update-m1n1

[ -n "$M1N1_UPDATE_DISABLED" ] && exit 0

. /usr/share/asahi-scripts/functions.sh

: ${SOURCE:="/usr/lib/asahi-boot/"}
: ${M1N1:="$SOURCE/m1n1.bin"}
: ${U_BOOT:="$SOURCE/u-boot-nodtb.bin"}
: ${TARGET:="$1"}
: ${DTBS:=$(/bin/ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb}
: ${CONFIG:=/etc/m1n1.conf}

if [ -z "$DTBS" ]; then
    exit 1
fi

m1n1config=/run/m1n1.conf
>"$m1n1config"

if [ -e "$CONFIG" ]; then
    while read line; do
        case "$line" in
            "") ;;
            \#*) ;;
            chosen.*=*|display=*|mitigations=*)
                echo "$line" >> "$m1n1config"
                ;;
        esac
    done <$CONFIG
fi

cat "$M1N1" $DTBS >"${TARGET}.new"
gzip -c "$U_BOOT" >>"${TARGET}.new"
cat "$m1n1config" >>"${TARGET}.new"
SH
}

# Newer asahi-scripts expand a DTBS that is a directory.
add_directory_expansion() {
  sed -i '/^if \[ -z "\$DTBS" \]; then$/i if [ -d "$DTBS" ] || [ -d "${UPDATE_M1N1_TEST_ROOT:-}$DTBS" ]; then\n    DTBS="${DTBS}/apple/t6*.dtb ${DTBS}/apple/t81*.dtb"\nfi\n' "$root/usr/bin/update-m1n1"
}

# A device tree as update-m1n1 and the boot check see one: the flattened device
# tree magic and big-endian total size, then a body naming it.
write_dtb() {
  local body size
  body="device tree ${1##*/}"$'\n'
  size=$(( 8 + ${#body} ))
  mkdir -p "$(dirname "$root$1")"
  {
    printf '\xd0\x0d\xfe\xed'
    printf "$(printf '\\x%02x' $(( size >> 24 & 255 )) $(( size >> 16 & 255 )) $(( size >> 8 & 255 )) $(( size & 255 )))"
    printf '%s' "$body"
  } >"$root$1"
}

# boot.bin as update-m1n1 would have written it from the given device trees.
write_boot_bin() {
  local dtb paths=()
  for dtb; do
    paths+=("$root$dtb")
  done
  mkdir -p "$esp/m1n1"
  {
    cat "$root/usr/lib/asahi-boot/m1n1.bin" "${paths[@]}"
    gzip -c "$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
    printf 'chosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\nmitigations=off\n'
  } >"$esp/m1n1/boot.bin"
}

# boot.bin as update-m1n1 writes it with the fixture's overlaid t8103 device tree.
write_overlaid_boot_bin() {
  local body size
  overlaid="$test_tmp/t8103-j274.dtb"
  body="device tree t8103-j274.dtb"$'\n'"overlay omarchy-ane.dtbo"$'\n'
  size=$(( 8 + ${#body} ))
  {
    printf '\xd0\x0d\xfe\xed'
    printf "$(printf '\\x%02x' $(( size >> 24 & 255 )) $(( size >> 16 & 255 )) $(( size >> 8 & 255 )) $(( size & 255 )))"
    printf '%s' "$body"
  } >"$overlaid"
  mkdir -p "$esp/m1n1"
  {
    cat "$root/usr/lib/asahi-boot/m1n1.bin" "$root${dtbs[0]}" "$root${dtbs[1]}" "$overlaid"
    gzip -c "$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
    printf 'chosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\nmitigations=off\n'
  } >"$esp/m1n1/boot.bin"
}

# A Mac booting $1 with its m1n1; $2 onwards are its device tree names.
system() {
  local kernel=$1 bootloader=m1n1-aurora
  shift
  [[ $kernel == linux-aurora ]] && kver=6.17.0-aurora1-ARCH || { kver=6.14.8-asahi1-1-ARCH bootloader=m1n1; }
  modules="$root/usr/lib/modules/$kver"
  dtbs=()
  for name in "${@:-t6000-j314s.dtb t6020-j414s.dtb t8103-j274.dtb}"; do
    for dtb in $name; do
      dtbs+=("/usr/lib/modules/$kver/dtbs/$dtb")
    done
  done
  rm -rf "$root" "$esp_device" "$existing" "$test_tmp/files"
  mkdir -p "$modules/dtbs" "$root/boot/grub" "$root/usr/lib/asahi-boot" "$root/etc/default" "$root/run" "$esp/m1n1" "$test_tmp/files"
  : >"$mounts"
  ln -s usr/lib "$root/lib"
  printf '%s kernel %s\n' "$kernel" "$kver" >"$modules/vmlinuz"
  cp "$modules/vmlinuz" "$root/boot/vmlinuz-$kernel"
  printf 'initramfs\n' >"$root/boot/initramfs-$kernel.img"
  printf 'linux /vmlinuz-%s root=UUID=x\ninitrd /initramfs-%s.img\n' "$kernel" "$kernel" >"$root/boot/grub/grub.cfg"
  for dtb in "${dtbs[@]}"; do
    write_dtb "$dtb"
  done
  printf 'm1n1 stage 2 from %s\n' "$bootloader" >"$root/usr/lib/asahi-boot/m1n1.bin"
  printf 'u-boot\n' >"$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
  printf '# options\nchosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\n   mitigations=off\nunknown=1\n\n' >"$root/etc/m1n1.conf"
  write_update_m1n1
  dtc_tools 1.8.1
  printf '%s\n' "$kernel" "$kernel-headers" "$bootloader" uboot-asahi >"$test_tmp/files/installed"
  {
    printf '/usr/\n/usr/lib/\n/usr/lib/modules/\n/usr/lib/modules/%s/\n/usr/lib/modules/%s/vmlinuz\n' "$kver" "$kver"
    printf '/usr/lib/modules/%s/dtbs/\n' "$kver"
    printf '%s\n' "${dtbs[@]}"
  } >"$test_tmp/files/$kernel"
  printf '/usr/lib/asahi-boot/\n/usr/lib/asahi-boot/m1n1.bin\n' >"$test_tmp/files/$bootloader"
  printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
  write_boot_bin "${dtbs[@]}"
  pkgver=6.14.8-1
  archive_sha=$(printf '%064d' 1)
  if [[ $kernel == linux-aurora ]]; then
    pkgver=6.17.0.aurora1-1
    mkdir -p "$root/var/lib/omarchy"
    {
      printf 'format=1\nchannel=aurora\nrelease_tag=aurora-packages-1c5e34c99dc2510bf06c673165a79aa92c8f1f4c\n'
      printf 'package=1|linux-aurora|%s|aarch64|linux-aurora.pkg.tar.zst|%s|linux-aurora.pkg.tar.zst.sig|%064d\n' \
        "$pkgver" "$archive_sha" 2
    } >"$root/var/lib/omarchy/aurora-target.descriptor"
    printf 'format=1\nlane=rc\n' >"$root/var/lib/omarchy/apple-silicon-aurora-lane"
    printf 'format=1\nchannel=rc\nkernel=linux-aurora\n' >"$root/var/lib/omarchy/apple-silicon-channel"
  fi
  printf '%s\n' "$pkgver" >"$test_tmp/files/version-$kernel"
}

run_check() {
  : >"$calls"
  set +e
  env -u LC_ALL -u LC_COLLATE LANG="${TEST_LANG:-C}" \
    TEST_CALLS="$calls" \
    TEST_FILES="$test_tmp/files" \
    TEST_INITRAMFS_LIST="$test_tmp/initramfs" \
    TEST_MOUNTS="$mounts" \
    TEST_PARTUUID=$partuuid \
    TEST_ESP_DEVICE="$esp_device" \
    TEST_QKK_FAIL="${TEST_QKK_FAIL:-}" \
    TEST_QKK_DEPMOD="${TEST_QKK_DEPMOD:-}" \
    TEST_QKK_NODB="${TEST_QKK_NODB:-}" \
    OMARCHY_BOOT_CHECK_ROOT="$root" \
    OMARCHY_BOOT_CHECK_UNAME="${TEST_UNAME:-$kver}" \
    OMARCHY_APPLE_SILICON_CHANNEL_ROOT="$root" \
    OMARCHY_APPLE_SILICON_CHANNEL_TESTING=1 \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$check" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
  status=$?
  set -e
}

# Every mount is read-only from the start, or a bind remounted read-only before
# anything reads it, and nothing is left mounted.
mounts_were_read_only() {
  ! grep '^mount ' "$calls" | grep -Ev -- ' -o (ro|remount,bind,ro) ' | grep -q . ||
    fail "$1 never mounts the ESP writable" "$(grep '^mount ' "$calls")"
  [[ ! -s $mounts && -z $(ls -A "$root/run") ]] || fail "$1 leaves nothing mounted" "$(cat "$mounts"; ls -A "$root/run")"
}

expect_pass() {
  (( status == 0 )) || fail "$1 passes" "status $status: $(cat "$test_tmp/err")"
  mounts_were_read_only "$1"
}

expect_fail() {
  local description=$1 message=$2
  (( status == 1 )) || fail "$description fails the check" "status $status: $(cat "$test_tmp/err")"
  grep -Fq "$message" "$test_tmp/err" || fail "$description is explained" "$(cat "$test_tmp/err")"
  mounts_were_read_only "$description"
}

# The check with an empty root, as on a real Mac: the fixture moves onto the
# container's own filesystem, at its real paths. Only CI runs these rows, as
# root in its throwaway Arch container (OMARCHY_TEST_SYSTEM_ROOT=1), and they
# refuse to overwrite any file that already exists. update-m1n1 and the dtc
# tools that run are the real ones on that filesystem.
if [[ ${OMARCHY_TEST_SYSTEM_ROOT:-} == 1 ]]; then
  (( EUID == 0 )) && [[ -f /.dockerenv ]] || fail "the empty-root rows run only as root in a throwaway container"
  system linux-aurora
  rm "$root/usr/bin/dtc" "$root/usr/bin/fdtoverlay" "$root/usr/bin/fdtget" "$root/usr/bin/dtc-version"
  for dtb in "${dtbs[@]}"; do
    name=${dtb##*/}
    dtc -q -I dts -O dtb -o "$root$dtb" - <<DTS
/dts-v1/;
/ {
  compatible = "apple,${name%.dtb}", "apple,${name%%-*}";
  #address-cells = <2>;
  #size-cells = <2>;
  soc { compatible = "simple-bus"; #address-cells = <2>; #size-cells = <2>; ranges; };
};
DTS
  done
  write_boot_bin "${dtbs[@]}"
  cp "$ROOT/files/etc/default/update-m1n1" "$root/etc/default/update-m1n1"
  mkdir -p "$root/usr/lib/omarchy-mac/boot" "$root/usr/share/asahi-scripts" "$root/usr/lib/omarchy-mac-boot/dtb-overlays"
  cp "$ROOT/lib/dtb-overlays.sh" "$root/usr/lib/omarchy-mac/boot/dtb-overlays.sh"
  : >"$root/usr/share/asahi-scripts/functions.sh"
  while IFS= read -r path; do
    [[ ! -e /$path && ! -L /$path ]] || fail "the empty-root rows would overwrite /$path"
  done < <(cd "$root" && find usr etc boot var -type f -o -type l)
  for top in usr etc boot var; do
    cp -a "$root/$top/." "/$top/"
  done
  root=""

  run_check
  (( status == 0 )) || fail "the check with an empty root and the default DTBS glob passes" "status $status: $(cat "$test_tmp/err")"
  [[ ! -s $mounts ]] || fail "the empty-root check leaves nothing mounted" "$(cat "$mounts")"

  mkdir /usr/lib/omarchy-mac-boot/dtb-overlays/t8103
  dtc -q -@ -I dts -O dtb -o /usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo - <<'DTS' ||
/dts-v1/;
/plugin/;
/ {
  fragment@0 {
    target-path = "/soc";
    __overlay__ { ane@2000 { compatible = "apple,t8103-ane"; reg = <0 0x2000 0 0x100>; }; };
  };
};
DTS
    fail "the real dtc compiles the test overlay"
  printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
  /bin/sh /usr/bin/update-m1n1 /boot/efi/m1n1/boot.bin
  mv /boot/efi/m1n1/boot.bin.new /boot/efi/m1n1/boot.bin
  [[ $(cat /run/omarchy-dtb-overlays/manifest) == "overlay3 "*"/modules/$kver/dtbs/t8103-j274.dtb" ]] ||
    fail "the real update-m1n1 overlays the t8103 device tree" "$(cat /run/omarchy-dtb-overlays/manifest)"
  run_check
  (( status == 0 )) || fail "the check with an empty root vouches the overlaid image" "status $status: $(cat "$test_tmp/err")"
  ! grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err" ||
    fail "the empty-root check prints no warning" "$(cat "$test_tmp/err")"
  pass "with an empty root, the check globs the default DTBS and vouches the image the real update-m1n1 overlays"
  exit 0
fi

# Both kernel and bootloader pairs, named or detected.
system linux-aurora
run_check
expect_pass "linux-aurora with m1n1-aurora, detected"
grep -Fq "running linux-aurora $kver; installed boot files match" "$test_tmp/out" ||
  fail "a passing check reports the installed kernel identity" "$(cat "$test_tmp/out")"
grep -Eq "^mount --bind -o ro $esp $root/run/omarchy-esp\.[A-Za-z0-9]{6}\$" "$calls" ||
  fail "without an ESP in the device tree, /boot/efi is bound read-only at a private mountpoint" "$(cat "$calls")"
[[ ! -e $root/run/m1n1.conf ]] || fail "/run/m1n1.conf is not rewritten"
run_check linux-aurora
expect_pass "linux-aurora, named"

# An encrypted root during the first-boot window: the systemd initramfs
# carries sd-encrypt as the cryptsetup generator and binary, never as a
# runtime hook, and lsinitcpio -a names no hook for it.
system linux-aurora
mkdir -p "$root/etc" "$root/var/lib/omarchy/mac-first-boot" "$root/boot/omarchy"
printf '/dev/mapper/root / btrfs subvol=@ 0 0\n' >"$root/etc/fstab"
printf 'root UUID=0422663f-9969-4953-900f-b342703b7e84 none luks\n' >"$root/etc/crypttab"
printf 'linux /vmlinuz-linux-aurora root=/dev/mapper/root rd.luks.name=0422663f-9969-4953-900f-b342703b7e84=root rd.luks.key=0422663f-9969-4953-900f-b342703b7e84=/omarchy/luks-key:UUID=b\ninitrd /initramfs-linux-aurora.img\n' >"$root/boot/grub/grub.cfg"
: >"$root/var/lib/omarchy/mac-first-boot/pending"
printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\nusr/bin/systemd-cryptsetup\nusr/lib/systemd/system-generators/systemd-cryptsetup-generator\n' "$kver" >"$test_tmp/initramfs"
printf '==> Image: initramfs\n==> Early hook run order:\n  asahi\n==> Late hook run order:\n  asahi\n' >"$test_tmp/initramfs.analyze"
run_check linux-aurora
expect_pass "an encrypted root whose systemd initramfs carries the cryptsetup generator"
printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
run_check linux-aurora
expect_fail "an encrypted root whose initramfs lacks sd-encrypt" "/boot/initramfs-linux-aurora.img does not contain sd-encrypt"
# A Mac installed before Omarchy's images: the busybox init unlocks the root
# through the encrypt hook and cryptdevice=, with no crypttab and none of
# Omarchy's sd-encrypt provisioning. The busybox init keeps only the last
# rootflags=, so a second one is a boot that loses subvol=@.
system linux-asahi
printf '/dev/mapper/root / btrfs subvol=@ 0 0\n' >"$root/etc/fstab"
printf 'linux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@ cryptdevice=UUID=0422663f-9969-4953-900f-b342703b7e84:root:allow-discards quiet\ninitrd /initramfs-linux-asahi.img\n' >"$root/boot/grub/grub.cfg"
printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\ninit_functions\nhooks/encrypt\n' "$kver" >"$test_tmp/initramfs"
printf '==> Image: initramfs\n==> Hook run order:\n  base\n  udev\n  encrypt\n' >"$test_tmp/initramfs.analyze"
export TEST_LSBLK_CHAIN="/dev/mapper/root btrfs\n/dev/nvme0n1p5 crypto_LUKS\n/dev/nvme0n1 \n"
export TEST_LUKS_UUID=0422663f-9969-4953-900f-b342703b7e84
run_check
expect_pass "a busybox encrypt root unlocked by cryptdevice="
run_check --boot-chain
expect_pass "a busybox encrypt root unlocked by cryptdevice=, checked for the next boot"
sed -i 's/ quiet$/ rootflags=x-systemd.device-timeout=0 quiet/' "$root/boot/grub/grub.cfg"
run_check
expect_fail "a busybox encrypt root with a second rootflags=" "more than one rootflags="
run_check --boot-chain
expect_fail "a busybox encrypt root with a second rootflags=, checked for the next boot" "more than one rootflags="
sed -i 's/ cryptdevice=[^ ]*//; s/ rootflags=x-systemd.device-timeout=0//' "$root/boot/grub/grub.cfg"
run_check
expect_fail "a busybox encrypt root without cryptdevice=" "does not set cryptdevice="
sed -i 's| rw | rw cryptdevice=UUID=11111111-2222-3333-4444-555555555555:root |' "$root/boot/grub/grub.cfg"
run_check
expect_fail "a busybox encrypt root whose cryptdevice= names another partition" "does not name the LUKS partition"
printf 'linux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@\nlinux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@ cryptdevice=UUID=0422663f-9969-4953-900f-b342703b7e84:root single\ninitrd /initramfs-linux-asahi.img\n' >"$root/boot/grub/grub.cfg"
run_check
expect_fail "a busybox encrypt entry without cryptdevice= beside one with it" "does not set cryptdevice="
printf '#linux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@\n#initrd /initramfs-linux-asahi.img\n' >"$root/boot/grub/grub.cfg"
run_check
expect_fail "a busybox encrypt root with only commented kernel lines" "has no linux entry for vmlinuz-linux-asahi"
# grub-mkconfig's sections: only 10_linux's entries boot this root; os-prober
# lists other installs, whose command lines are theirs.
grub_sections() {
  printf '### BEGIN /etc/grub.d/10_linux ###\nmenuentry Omarchy {\n  linux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@ %s quiet\n  initrd /initramfs-linux-asahi.img\n}\n### END /etc/grub.d/10_linux ###\n' "$1"
  printf '### BEGIN /etc/grub.d/30_os-prober ###\nmenuentry Other {\n  linux /vmlinuz-linux-asahi root=UUID=y rw rootflags=subvol=@ rootflags=subvol=@home\n}\n### END /etc/grub.d/30_os-prober ###\n'
}
grub_sections cryptdevice=UUID=0422663f-9969-4953-900f-b342703b7e84:root >"$root/boot/grub/grub.cfg"
run_check --boot-chain
expect_pass "a busybox encrypt root beside another install os-prober found"
grub_sections "" >"$root/boot/grub/grub.cfg"
run_check --boot-chain
expect_fail "a busybox encrypt root whose own section lacks cryptdevice=" "does not set cryptdevice="
# An image with the encrypt hook and a systemd init runs systemd: the
# sd-encrypt and crypttab checks still apply.
printf 'linux /vmlinuz-linux-asahi root=UUID=x rw rootflags=subvol=@ cryptdevice=UUID=0422663f-9969-4953-900f-b342703b7e84:root quiet\ninitrd /initramfs-linux-asahi.img\n' >"$root/boot/grub/grub.cfg"
printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\ninit_functions\nhooks/encrypt\nusr/lib/systemd/systemd\n' "$kver" >"$test_tmp/initramfs"
run_check
expect_fail "a systemd image carrying the encrypt hook" "encrypted root has no crypttab"
printf 'usr/lib/modules/%s/kernel/drivers/gpu/drm/apple/appledrm.ko.zst\nusr/bin/init\n' "$kver" >"$test_tmp/initramfs"
printf '==> Image: initramfs\n==> Hook run order:\n  base\n  udev\n' >"$test_tmp/initramfs.analyze"
run_check
expect_fail "an encrypted root with neither crypttab nor the encrypt hook" "encrypted root has no crypttab"
unset TEST_LSBLK_CHAIN TEST_LUKS_UUID
printf '==> Image: initramfs\n==> Early hook run order:\n  asahi\n==> Late hook run order:\n  asahi\n' >"$test_tmp/initramfs.analyze"
pass "a busybox encrypt root is checked for cryptdevice= and one rootflags= on every one of its own entries, and only a busybox image counts"
system linux-asahi
run_check
expect_pass "linux-asahi with m1n1, detected"
run_check linux-asahi
expect_pass "linux-asahi, named"
printf 'the previous kernel\n' >"$root/boot/vmlinuz-linux-asahi"
run_check
expect_fail "a stale linux-asahi kernel" "/boot/vmlinuz-linux-asahi is not the 6.14.8-asahi1-1-ARCH kernel linux-asahi installed"
pass "linux-aurora with m1n1-aurora and linux-asahi with m1n1 are both checked, named or detected"

system linux-aurora
run_check linux-asahi
expect_fail "a kernel that is not installed" "linux-asahi boots with m1n1, but linux-asahi is not installed"
run_check linux-zen
expect_fail "a kernel outside the allowlist" "linux-zen is not a kernel this check knows"
printf 'linux-asahi\n' >>"$test_tmp/files/installed"
run_check
expect_fail "both kernels installed" "cannot tell which kernel boots: linux-aurora linux-asahi installed"
run_check linux-aurora
expect_fail "both kernels, one named" "linux-aurora boots with m1n1-aurora, but linux-asahi is installed too"
printf 'uboot-asahi\n' >"$test_tmp/files/installed"
run_check
expect_fail "no known kernel installed" "cannot tell which kernel boots: neither linux-aurora nor linux-asahi installed"
printf 'linux-aurora\nm1n1\n' >"$test_tmp/files/installed"
run_check
expect_fail "linux-aurora with the Asahi m1n1" "linux-aurora boots with m1n1-aurora, but m1n1-aurora is not installed"
pass "a missing, unknown, ambiguous or mismatched kernel and bootloader pair fails"

# The ESP is only ever read through a read-only mount.
system linux-aurora
mkdir -p "$root/proc/device-tree/chosen" "$esp_device"
printf '%s\0' "$partuuid" >"$root/proc/device-tree/chosen/asahi,efi-system-partition"
cp -a "$esp/." "$esp_device/"
rm -rf "$esp/m1n1"
run_check
expect_pass "an ESP named in the device tree and not mounted"
grep -Eq "^mount -o ro PARTUUID=$partuuid $root/run/omarchy-esp\.[A-Za-z0-9]{6}\$" "$calls" ||
  fail "an unmounted ESP is mounted read-only by its PARTUUID" "$(cat "$calls")"
TEST_RO_REFUSED=1 run_check
expect_fail "an ESP the kernel will not mount read-only" "cannot mount the system ESP (PARTUUID=$partuuid) read-only"
(( $(grep -c '^mount ' "$calls") == 1 )) || fail "a refused read-only mount is not retried writable" "$(cat "$calls")"
cp -a "$esp_device" "$existing"
TEST_EXISTING_MOUNT="$existing" run_check
expect_pass "an ESP that is already mounted"
grep -Eq "^mount --bind -o ro $existing $root/run/omarchy-esp\." "$calls" && ! grep -q "PARTUUID=$partuuid $root" "$calls" ||
  fail "an ESP already mounted is bound read-only from its mount, not mounted again" "$(cat "$calls")"
TEST_EXISTING_MOUNT="$existing" TEST_BIND_COMES_UP_RW=1 run_check
expect_pass "a bind that comes up writable"
grep -q '^mount -o remount,bind,ro ' "$calls" || fail "a writable bind is made read-only before anything reads it" "$(cat "$calls")"
TEST_EXISTING_MOUNT="$existing" TEST_BIND_COMES_UP_RW=1 TEST_REMOUNT_FAILS=1 run_check
expect_fail "a bind that cannot be made read-only" "cannot bind the system ESP (PARTUUID=$partuuid) read-only from $existing"
grep -q "^umount $root/run/omarchy-esp\." "$calls" || fail "a bind that stays writable is unmounted unread" "$(cat "$calls")"
TEST_EXISTING_MOUNT="$test_tmp/gone" run_check
expect_fail "an ESP mount that cannot be read" "is mounted at $test_tmp/gone, which cannot be read"
: >"$root/boot/efi/.builder"
mkdir -p "$esp/m1n1"
cp "$esp_device/m1n1/boot.bin" "$esp/m1n1/"
run_check
expect_pass "a builder image"
grep -Eq "^mount --bind -o ro $esp " "$calls" || fail "a builder image reads /boot/efi like mount_sys_esp" "$(cat "$calls")"
pass "the ESP is mounted read-only, or its existing mount bound read-only, and never mounted writable"

# What a failed hook after the transaction leaves behind.
system linux-aurora
printf 'the previous kernel\n' >"$root/boot/vmlinuz-linux-aurora"
run_check
expect_fail "a /boot kernel mkinitcpio did not replace" "/boot/vmlinuz-linux-aurora is not the $kver kernel"
system linux-aurora
printf 'usr/lib/modules/6.16.0-aurora9-ARCH/kernel/x.ko\n' >"$test_tmp/initramfs"
run_check
expect_fail "an initramfs built for the previous kernel" "does not hold the $kver modules"
system linux-aurora
printf 'linux /vmlinuz-linux-aurora\n' >"$root/boot/grub/grub.cfg"
run_check
expect_fail "a GRUB entry without the initramfs" "grub.cfg does not boot vmlinuz-linux-aurora with initramfs-linux-aurora.img"
system linux-aurora
write_boot_bin "${dtbs[@]:0:2}"
run_check
expect_fail "an m1n1 image update-m1n1 did not rebuild" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1, linux-aurora $kver's device trees"
system linux-aurora
rm "$esp/m1n1/boot.bin"
run_check
expect_fail "an ESP without m1n1" "has no m1n1/boot.bin"
system linux-aurora
printf 'M1N1_UPDATE_DISABLED=1\n' >"$root/etc/default/update-m1n1"
run_check
expect_fail "m1n1 updates disabled" "M1N1_UPDATE_DISABLED is set"
system linux-aurora
printf 'stray\n' >"$modules/dtbs/zz-stray.dtb"
run_check
expect_fail "a device tree the kernel does not own" "device tree /lib/modules/$kver/dtbs/zz-stray.dtb is not owned by linux-aurora"
pass "a stale kernel, initramfs, GRUB entry or m1n1 image, disabled m1n1 updates and a stray device tree all fail"

# A package-owned overlay: update-m1n1 applies it to the kernel's device trees
# (dtb-overlays.sh), and the rebuild applies it the same way.
system linux-aurora
cp "$ROOT/files/etc/default/update-m1n1" "$root/etc/default/update-m1n1"
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
run_check --boot-chain
expect_fail "an overlay update-m1n1 has not applied yet" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1"
write_overlaid_boot_bin
run_check --boot-chain
expect_pass "an m1n1 image update-m1n1 built with the overlaid device tree"
run_check
expect_pass "an m1n1 image with the overlaid device tree, in the full check"
[[ -z $(ls -A "$root/run") ]] || fail "the rebuild writes the overlaid device tree only to its own work directory"
# An edited configuration kept over the packaged one's .pacnew, and no
# configuration at all: update-m1n1 never applies the overlays, nor does the rebuild.
write_boot_bin "${dtbs[@]}"
printf 'export LC_ALL=C\n# dtb_overlays_update_m1n1\n' >"$root/etc/default/update-m1n1"
for config in edited missing; do
  [[ $config == "edited" ]] || rm "$root/etc/default/update-m1n1"
  run_check --boot-chain
  expect_pass "an m1n1 image built without the overlays, with the configuration $config"
  grep -Fq "does not apply the device tree overlays" "$test_tmp/err" ||
    fail "the check says the $config configuration leaves the overlays out" "$(cat "$test_tmp/err")"
done
cp "$ROOT/files/etc/default/update-m1n1" "$root/etc/default/update-m1n1"
run_check --boot-chain
expect_fail "an m1n1 image built without the overlays the packaged configuration applies" "m1n1/boot.bin on the system ESP (/boot/efi) is not m1n1"
rm "$root/etc/default/update-m1n1"
: >"$test_tmp/files/owners"
run_check --boot-chain
expect_fail "an overlay no package owns" "device tree overlay /usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo is not owned by a package"
pass "package-owned device tree overlays are rebuilt into m1n1 stage 2 where the configuration applies them, and an unowned one fails"

mkdir -p "$ROOT/test/fixtures/asahi-scripts"
: >"$ROOT/test/fixtures/asahi-scripts/functions.sh"

# Runs the fixture update-m1n1 the way update-m1n1 runs: /bin/sh, the real
# library, the fixture root, the fixture's dtc tools, and the caller's locale.
# Its boot.bin is the one the check must vouch for.
run_update_m1n1() {
  local translate=(
    -e "s|/etc/default/update-m1n1|$test_tmp/update-m1n1-config|g"
    -e "s|/usr/share/asahi-scripts/functions.sh|$ROOT/test/fixtures/asahi-scripts/functions.sh|g"
    -e "s|/usr/lib/omarchy-mac/boot/dtb-overlays.sh|$test_tmp/lib-fixture.sh|g"
    -e "s|/usr/lib/asahi-boot|$root/usr/lib/asahi-boot|g"
    -e "s|/lib/modules/|$root/lib/modules/|g"
    -e "s|/etc/m1n1.conf|$root/etc/m1n1.conf|g"
    -e "s|/run/m1n1.conf|$test_tmp/m1n1.conf|g"
    -e 's|DTBS="\${DTBS}/apple/t6\*\.dtb \${DTBS}/apple/t81\*\.dtb"|DTBS="${UPDATE_M1N1_TEST_ROOT}${DTBS}/apple/t6*.dtb ${UPDATE_M1N1_TEST_ROOT}${DTBS}/apple/t81*.dtb"|'
  )
  # The library the fixture sources redirects its copies the way the boot
  # check's shim does: dtb_overlays_outdir is replaced, never the environment.
  printf '. %s\ndtb_overlays_outdir() {\n  printf "%%s\\n" %s\n}\n' \
    "'$ROOT/lib/dtb-overlays.sh'" "'$test_tmp/expected-out'" >"$test_tmp/lib-fixture.sh"
  sed "${translate[@]}" "$root/usr/bin/update-m1n1" >"$test_tmp/update-m1n1-runnable"
  sed -e "s|/usr/lib/omarchy-mac/boot/dtb-overlays.sh|$test_tmp/lib-fixture.sh|g" \
    "$root/etc/default/update-m1n1" >"$test_tmp/update-m1n1-config"
  OMARCHY_DTB_OVERLAYS_ROOT=$root \
  PATH="$root/usr/bin:/usr/bin:/bin" \
  UPDATE_M1N1_TEST_ROOT=$root \
  LANG="${TEST_LANG:-C}" \
    /bin/sh "$test_tmp/update-m1n1-runnable" "$1"
  mv "$1.new" "$1"
}

# The matrix: every configuration the packaged one can meet. The expected
# boot.bin comes from the fixture update-m1n1 running the real library; the
# check must vouch those bytes and print none of its own warnings.
matrix_row() {
  local overlays=$1 optout=$2 dtbs_state=$3 dtc=$4
  local label="matrix $overlays/$optout/$dtbs_state/$dtc"
  # A configuration that keeps the call's merged DTBS only while an overlay
  # applies, the opt-out stays quiet, and old dtc never assigns: the warning
  # is expected exactly when the call ran and a later line dropped its copies.
  local overwrites=0
  if [[ $overlays == applies && $optout == none && $dtc == ok ]]; then
    case $dtbs_state in after | 'unset after' | 'same value after' | 'default+ after') overwrites=1 ;; esac
  fi
  # The directory rows keep the trees where update-m1n1's expansion looks.
  [[ $dtbs_state == directory ]] &&
    system linux-aurora 'apple/t6000-j314s.dtb apple/t6020-j414s.dtb apple/t8103-j274.dtb' ||
    system linux-aurora
  case $overlays in
    applies)
      mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
      printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
      printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
      ;;
    none-applies)
      mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8123"
      printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8123/omarchy-ane.dtbo"
      printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8123/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
      ;;
  esac
  local optline="" pre="" post=""
  case $optout in
    '=0') optline='OMARCHY_DTB_OVERLAYS=0' ;;
    quoted) optline='OMARCHY_DTB_OVERLAYS="0"' ;;
  esac
  case $dtbs_state in
    above) pre="DTBS=\"${dtbs[*]}\"" ;;
    after) post="DTBS=\"${dtbs[*]}\"" ;;
    ':= after') post=": \${DTBS:=\"${dtbs[*]}\"}" ;;
    'append after') post='DTBS="$DTBS /x.dtb"' ;;
    'unset after') post='unset DTBS' ;;
    'same value after') pre="DTBS=\"${dtbs[*]}\"" post="DTBS=\"${dtbs[*]}\"" ;;
    'default= after') post="DTBS=\${DTBS=\"${dtbs[0]}\"}" ;;
    'default- after') post="DTBS=\${DTBS-\"${dtbs[0]}\"}" ;;
    'default+ after') post="DTBS=\${DTBS+\"${dtbs[0]}\"}" ;;
    directory) pre="DTBS=/usr/lib/modules/$kver/dtbs" ;;
  esac
  {
    [[ -z $optline ]] || printf '%s\n' "$optline"
    [[ -z $pre ]] || printf '%s\n' "$pre"
    cat "$ROOT/files/etc/default/update-m1n1"
    [[ -z $post ]] || printf '%s\n' "$post"
  } >"$root/etc/default/update-m1n1"
  [[ $dtbs_state == directory ]] && add_directory_expansion
  [[ $dtc == old ]] && dtc_tools 1.6.1
  if [[ $dtbs_state == 'append after' ]]; then
    run_check --boot-chain
    expect_fail "$label" "device tree /x.dtb does not exist"
  else
    run_update_m1n1 "$esp/m1n1/boot.bin"
    run_check --boot-chain
    expect_pass "$label"
    if [[ $overlays == applies && $overwrites == 1 ]]; then
      grep -Fq "overwrites DTBS" "$test_tmp/err" ||
        fail "the $label row explains the overwritten DTBS" "$(cat "$test_tmp/err")"
    elif grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err"; then
      fail "spurious warning in the $label row" "$(cat "$test_tmp/err")"
    fi
  fi
  unset TEST_LANG
}
for overlays in none applies none-applies; do
  for optout in none '=0' quoted; do
    for dtbs_state in above after ':= after' 'append after' 'unset after' 'same value after' directory 'default= after' 'default- after' 'default+ after'; do
      for dtc in ok old; do
        matrix_row "$overlays" "$optout" "$dtbs_state" "$dtc"
      done
    done
  done
done
# The same merge under a non-C locale, with the pin dropped from the copy:
# the order follows that locale, and the check still vouches the bytes.
system linux-aurora
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
sed '/LC_ALL/d' "$ROOT/files/etc/default/update-m1n1" >"$root/etc/default/update-m1n1"
TEST_LANG=en_US.UTF-8 run_update_m1n1 "$esp/m1n1/boot.bin"
TEST_LANG=en_US.UTF-8 run_check
expect_pass "a merged device tree order under a non-C locale"
grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err" &&
  fail "spurious warning under the non-C locale" "$(cat "$test_tmp/err")"
pass "the matrix of configurations vouches the image the real library and update-m1n1 build"

# Configurations read the way update-m1n1 reads them: a line that also sets or
# unsets OMARCHY_DTB_OVERLAYS_OUTDIR runs as it is while the shim keeps the
# copies in the workdir, the call counts only when it runs, and the
# configuration's own stderr is no library note.
packaged=$(cat "$ROOT/files/etc/default/update-m1n1")
config_row() {
  local label=$1 config=$2 warning=${3:-}
  system linux-aurora
  mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
  printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
  printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
  printf '%s\n' "$config" >"$root/etc/default/update-m1n1"
  run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
  rm -rf "$root/run/omarchy-dtb-overlays"
  run_check --boot-chain
  expect_pass "$label"
  if [[ -n $warning ]]; then
    grep -Fq "$warning" "$test_tmp/err" || fail "$label is explained" "$(cat "$test_tmp/err")"
  elif grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err"; then
    fail "no spurious warning: $label" "$(cat "$test_tmp/err")"
  fi
}
two="${dtbs[2]} ${dtbs[0]}"
config_row "a DTBS on the line that sets OMARCHY_DTB_OVERLAYS_OUTDIR" \
  "OMARCHY_DTB_OVERLAYS_OUTDIR=$test_tmp/elsewhere DTBS=\"$two\""$'\n'"$packaged"
config_row "a DTBS on the line that unsets OMARCHY_DTB_OVERLAYS_OUTDIR" \
  "unset OMARCHY_DTB_OVERLAYS_OUTDIR; DTBS=\"$two\""$'\n'"$packaged"
config_row "a call in a branch that never runs" \
  $'export LC_ALL=C\n. /usr/lib/omarchy-mac/boot/dtb-overlays.sh\nif false; then\n  dtb_overlays_update_m1n1\nfi' \
  "does not apply the device tree overlays"
config_row "a call that is not at the start of its line" \
  $'export LC_ALL=C\n. /usr/lib/omarchy-mac/boot/dtb-overlays.sh && dtb_overlays_update_m1n1'
config_row "a configuration that writes to stderr itself" \
  "echo 'dtb-overlays: a note from the configuration' >&2"$'\n'"$packaged"
! grep -Fq "a note from the configuration" "$test_tmp/err" ||
  fail "the configuration's own stderr is not replayed as a library note" "$(cat "$test_tmp/err")"
pass "the configuration copy keeps lines that touch the outdir, counts the call only when it runs, and replays only library notes"

# The outdir follows dtb_overlays_outdir, never the environment: a
# configuration that sets or unsets OMARCHY_DTB_OVERLAYS_OUTDIR moves nothing,
# neither for update-m1n1 nor for the check, and no directory of its own is
# created or touched.
system linux-aurora
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
printf 'unset OMARCHY_DTB_OVERLAYS_OUTDIR;OMARCHY_DTB_OVERLAYS_OUTDIR=%s\n%s\n' \
  "$test_tmp/slipped-out" "$packaged" >"$root/etc/default/update-m1n1"
run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
[[ -e $test_tmp/slipped-out ]] &&
  fail "the configuration's OMARCHY_DTB_OVERLAYS_OUTDIR moves nothing" "$test_tmp/slipped-out exists"
[[ -d $test_tmp/expected-out ]] || fail "the fixture keeps its copies in its own outdir"
run_check --boot-chain
expect_pass "adjacent unset and set of OMARCHY_DTB_OVERLAYS_OUTDIR move nothing"
grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err" &&
  fail "no spurious warning beside the adjacent outdir assignments" "$(cat "$test_tmp/err")"
[[ -e $test_tmp/slipped-out ]] &&
  fail "the check leaves the configuration's outdir alone" "$test_tmp/slipped-out exists after the check"
pass "the check touches no outdir but its own"

# A second call resolves the first call's copies back to their sources through
# the manifest before its cleanup, so it never deletes its own inputs and
# never aborts update-m1n1.
config_row "a second call after the first" \
  $'export LC_ALL=C\n. /usr/lib/omarchy-mac/boot/dtb-overlays.sh\ndtb_overlays_update_m1n1\ndtb_overlays_update_m1n1'

# Every DTBS word is its own occurrence: a tree that another word's overlaid
# copy also carries is built from its own word's file, in its position.
tree=${dtbs[0]}
system linux-aurora
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
printf 'DTBS="%s %s"\n%s\n' "$tree" "$tree" "$packaged" >"$root/etc/default/update-m1n1"
run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
run_check --boot-chain
expect_pass "the same tree twice builds and vouches occurrence by occurrence"
grep -Fq "Apple Silicon boot check: warning:" "$test_tmp/err" &&
  fail "no spurious warning for the repeated tree" "$(cat "$test_tmp/err")"
pass "a repeated DTBS word keeps its own occurrence"

config_row "a plain tree appended after its overlaid copy" \
  $'export LC_ALL=C\n. /usr/lib/omarchy-mac/boot/dtb-overlays.sh\ndtb_overlays_update_m1n1\n'"DTBS=\"\$DTBS $tree\""

# The same configuration, with a plain tree twice on the ESP where DTBS
# carries the overlaid copy first: refused, where one file per source path
# would build the plain expectation and accept it.
append_config=$packaged$'\n'"DTBS=\"\$DTBS $tree\""
system linux-aurora
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
printf '%s\n' "$append_config" >"$root/etc/default/update-m1n1"
run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
printf 'OMARCHY_DTB_OVERLAYS=0\nDTBS="%s %s"\n%s\n' "$tree" "$tree" "$packaged" >"$root/etc/default/update-m1n1"
run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
printf '%s\n' "$append_config" >"$root/etc/default/update-m1n1"
run_check --boot-chain
expect_fail "a plain tree twice is refused where DTBS carries the copy first" "with the package overlays"
pass "duplicate trees are tracked one occurrence at a time"

# update-m1n1 sources the configuration with set -e; a failing command there
# aborts update-m1n1, and the check refuses the same way instead of vouching
# for bytes update-m1n1 would never build.
system linux-aurora
printf 'false\nDTBS="%s %s"\n%s\n' "${dtbs[0]}" "${dtbs[2]}" "$packaged" >"$root/etc/default/update-m1n1"
run_check --boot-chain
expect_fail "a failing command before a valid assignment in the configuration" \
  "update-m1n1 would abort while reading /etc/default/update-m1n1"
pass "the check aborts where update-m1n1 aborts"

# A failed overlay is the library's one note, and the check replays it even
# though the configuration's own output is discarded.
system linux-aurora
mkdir -p "$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103"
printf 'overlay FAIL\n' >"$root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo"
printf '/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo omarchy-ane\n' >"$test_tmp/files/owners"
printf '%s\n' "$packaged" >"$root/etc/default/update-m1n1"
run_update_m1n1 "$esp/m1n1/boot.bin" 2>/dev/null
run_check --boot-chain
expect_pass "an overlay that does not apply leaves the kernel's device tree in place"
grep -Fq "dtb-overlays: $root/usr/lib/omarchy-mac-boot/dtb-overlays/t8103/omarchy-ane.dtbo does not apply to t8103-j274.dtb" \
  "$test_tmp/err" ||
  fail "the check replays the library's note" "$(cat "$test_tmp/err")"
pass "a failed overlay is reported through the one notes channel"

# dtb_list with the empty root of a real system: every word globs once, an
# unmatched glob stays literal as in update-m1n1, and the library's copies pass through.
(
  # shellcheck source=/dev/null
  source <(sed -n '/^dtb_list() {/,/^}/p' "$check")
  root="" dtbs_out=$test_tmp/copies real=$test_tmp/real-dtbs
  mkdir -p "$real/apple"
  : >"$real/apple/t6000-j314s.dtb"
  : >"$real/apple/t6020-j414s.dtb"
  : >"$real/t8103-j274.dtb"
  # shellcheck disable=SC2034 # dtb_list reads it
  DTBS="$real/apple/t60*.dtb $real/t8103-j274.dtb $dtbs_out/overlay3 $real/none*.dtb"
  mapfile -t got < <(dtb_list C)
  [[ ${got[*]} == "$real/apple/t6000-j314s.dtb $real/apple/t6020-j414s.dtb $real/t8103-j274.dtb $dtbs_out/overlay3 $real/none*.dtb" ]] ||
    fail "with an empty root, dtb_list globs each DTBS word" "${got[*]}"
)
pass "with an empty root, dtb_list globs every DTBS word the way update-m1n1 does"

# update-m1n1's defaults: := fills unset and empty settings alike.
for config in '' 'DTBS=\nSOURCE=""\n' 'CONFIG=\nM1N1=\nU_BOOT=\n' 'M1N1_UPDATE_DISABLED=\n'; do
  system linux-aurora
  [[ -z $config ]] || printf "$config" >"$root/etc/default/update-m1n1"
  run_check
  expect_pass "update-m1n1 configuration '$config'"
done
system linux-aurora
mkdir -p "$root/usr/lib/modules/6.9.0-asahi-ARCH/dtbs"
printf 'old\n' >"$root/usr/lib/modules/6.9.0-asahi-ARCH/dtbs/t8103-j274.dtb"
run_check
expect_pass "the newest -ARCH kernel is linux-aurora's"
mkdir -p "$root/usr/lib/modules/6.18.0-asahi-ARCH/dtbs"
printf 'newer\n' >"$root/usr/lib/modules/6.18.0-asahi-ARCH/dtbs/t8103-j274.dtb"
run_check
expect_fail "a newer kernel's device trees picked by the default" "is not one of linux-aurora $kver's"
system linux-aurora
printf 'DTBS="%s %s"\n' "${dtbs[2]}" "${dtbs[0]}" >"$root/etc/default/update-m1n1"
write_boot_bin "${dtbs[2]}" "${dtbs[0]}"
run_check
expect_pass "an explicit DTBS list, in its own order"
printf 'DTBS="/usr/lib/modules/%s/dtbs/*.dtb"\nTARGET=/boot/efi/m1n1/boot.bin\n' "$kver" >"$root/etc/default/update-m1n1"
write_boot_bin "${dtbs[@]}"
run_check
expect_pass "a DTBS glob, with a TARGET that is not read"
! compgen -G "$esp/m1n1/boot.bin.*" >/dev/null || fail "a configured TARGET is never written"
printf 'M1N1=/opt/m1n1.bin\n' >"$root/etc/default/update-m1n1"
mkdir -p "$root/opt"
printf 'custom m1n1\n' >"$root/opt/m1n1.bin"
{
  cat "$root/opt/m1n1.bin" "${dtbs[@]/#/$root}"
  gzip -c "$root/usr/lib/asahi-boot/u-boot-nodtb.bin"
  printf 'chosen.asahi,efi-system-partition=1234\ndisplay=2560x1600\nmitigations=off\n'
} >"$esp/m1n1/boot.bin"
run_check
expect_fail "a configured m1n1 no package owns" "M1N1 /opt/m1n1.bin is not owned by m1n1-aurora"
printf '/opt/m1n1.bin\n' >>"$test_tmp/files/m1n1-aurora"
run_check
expect_pass "a configured m1n1 its bootloader package owns"
pass "update-m1n1 defaults apply to unset and empty settings, and DTBS, M1N1 and the -ARCH default are honoured"

# A DTBS that is a directory: expanded only the way newer asahi-scripts do it.
system linux-aurora "apple/t6000-j314s.dtb apple/t8103-j274.dtb apple/t7000-other.dtb"
printf 'DTBS=/usr/lib/modules/%s/dtbs\n' "$kver" >"$root/etc/default/update-m1n1"
run_check
expect_fail "a directory this update-m1n1 does not expand" "DTBS names the directory /usr/lib/modules/$kver/dtbs, which this update-m1n1 does not expand"
add_directory_expansion
grep -Fq 'DTBS="${DTBS}/apple/t6*.dtb ${DTBS}/apple/t81*.dtb"' "$root/usr/bin/update-m1n1" || fail "the fixture expands directories"
write_boot_bin "${dtbs[0]}" "${dtbs[1]}"
run_check
expect_pass "a directory expanded to its t6 and t81 device trees"
write_boot_bin "${dtbs[@]}"
run_check
expect_fail "an image with a device tree the expansion leaves out" "is not m1n1"
sed -i 's|/apple/t81\*.dtb"|/apple/*.dtb"|' "$root/usr/bin/update-m1n1"
run_check
expect_fail "a directory expansion this check does not know" "expands a DTBS directory in a way this check does not recognise"
pass "a DTBS directory is expanded exactly as newer asahi-scripts do, and refused by an update-m1n1 that does not"

# update-m1n1 concatenates device trees in the collation it ran under: C once
# the shipped /etc/default/update-m1n1 pins it, the caller's before that. The
# check accepts exactly the expected device trees in any order, and no others.
utf8_locale=$(locale -a | grep -ixE 'en_US\.utf-?8' | head -1 || true)
if [[ -z $utf8_locale ]]; then
  mkdir -p "$test_tmp/locales"
  localedef -i en_US -f UTF-8 "$test_tmp/locales/en_US.UTF-8" 2>/dev/null ||
    fail "an en_US.UTF-8 locale is available or can be compiled for the collation fixture"
  export LOCPATH="$test_tmp/locales"
  utf8_locale=en_US.UTF-8
fi
names=(t6000-j314s.dtb t8103-j293.dtb t8103_j274.dtb)
mapfile -t c_order < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
mapfile -t utf8_order < <(printf '%s\n' "${names[@]}" | LC_ALL=$utf8_locale sort)
[[ ${c_order[*]} != "${utf8_order[*]}" ]] || fail "the fixture's device trees sort differently in C and $utf8_locale" "${c_order[*]}"
system linux-aurora "${names[*]}"
cp "$ROOT/files/etc/default/update-m1n1" "$root/etc/default/update-m1n1"
c_dtbs=("${c_order[@]/#//usr/lib/modules/$kver/dtbs/}")
utf8_dtbs=("${utf8_order[@]/#//usr/lib/modules/$kver/dtbs/}")
write_boot_bin "${c_dtbs[@]}"
TEST_LANG=$utf8_locale run_check
expect_pass "an image in C order under the shipped defaults, checked from a $utf8_locale session"
write_boot_bin "${utf8_dtbs[@]}"
TEST_LANG=C run_check
expect_pass "an image written in $utf8_locale order, checked from a C session"
TEST_LANG=$utf8_locale run_check
expect_pass "an image written in $utf8_locale order, checked from that session"
write_boot_bin "${c_dtbs[2]}" "${c_dtbs[0]}" "${c_dtbs[1]}"
run_check
expect_pass "the expected device trees in an order no collation gives"
write_boot_bin "${c_dtbs[0]}" "${c_dtbs[0]}" "${c_dtbs[1]}" "${c_dtbs[2]}"
run_check
expect_fail "a device tree carried twice" "is not m1n1"
write_boot_bin "${utf8_dtbs[@]:0:2}"
run_check
expect_fail "a device tree missing from a reordered image" "is not m1n1"
write_dtb /opt/t9999-foreign.dtb
write_boot_bin "${utf8_dtbs[@]}" /opt/t9999-foreign.dtb
run_check
expect_fail "a device tree the kernel does not ship" "is not m1n1"
write_boot_bin "${utf8_dtbs[@]}"
printf 'stale\n' >>"$esp/m1n1/boot.bin"
run_check
expect_fail "reordered device trees with a different tail" "is not m1n1"
pass "the device trees are compared as a set, with a real $utf8_locale locale, and nothing else may differ"

healthy_update_m1n1() {
  system linux-aurora
}
healthy_update_m1n1
sed -i '/DTBS:=/d' "$root/usr/bin/update-m1n1"
run_check
expect_fail "stock update-m1n1 without DTBS configured" "DTBS is unset or empty"
healthy_update_m1n1
sed -i 's|^: ${SOURCE:=.*|: ${SOURCE:=$(asahi-boot-dir)}|' "$root/usr/bin/update-m1n1"
run_check
expect_fail "a default this check cannot read" "has a SOURCE default this check does not recognise"
healthy_update_m1n1
sed -i '/^: ${CONFIG:=/d' "$root/usr/bin/update-m1n1"
run_check
expect_fail "a missing default" "has no CONFIG default this check recognises"
healthy_update_m1n1
sed -i 's|^gzip -c "$U_BOOT"|xz -c "$U_BOOT"|' "$root/usr/bin/update-m1n1"
run_check
expect_fail "an update-m1n1 that builds its image differently" "does not build m1n1/boot.bin the way this check rebuilds it"
pass "an update-m1n1 whose defaults or assembly are not recognised fails closed"

# Running-kernel identity is bound to installed packages, independently of
# Marcelo's channel descriptors and mutable switch journals.
system linux-aurora
TEST_UNAME=6.16.0-old-ARCH run_check
expect_fail "a running kernel that is not installed" "running kernel is 6.16.0-old-ARCH, not the installed linux-aurora $kver"
TEST_UNAME=6.16.0-old-ARCH OMARCHY_BOOT_CHECK_ALLOW_PENDING_REBOOT=1 run_check
expect_pass "an explicitly requested pending-reboot check"
rm -f "$root/var/lib/omarchy/aurora-target.descriptor"
run_check
expect_pass "boot verification needs no upstream release descriptor"
pass "boot verification is independent of upstream channels"

system linux-aurora
TEST_QKK_FAIL=linux-aurora run_check
expect_fail "altered linux-aurora files" "linux-aurora files do not match the package mtree"
unset TEST_QKK_FAIL
system linux-aurora
TEST_QKK_FAIL=m1n1-aurora run_check
expect_fail "altered m1n1-aurora files" "m1n1-aurora files do not match the package mtree"
unset TEST_QKK_FAIL
# depmod rewrites the modules.* files the kernel package ships on every install.
TEST_QKK_DEPMOD=linux-aurora run_check
expect_pass "depmod-rewritten modules.* files with only their modification time changed"
unset TEST_QKK_DEPMOD
TEST_QKK_FAIL=linux-aurora:modules-size run_check
expect_fail "a modules.* file of another size" "linux-aurora files do not match the package mtree"
TEST_QKK_FAIL=linux-aurora:missing run_check
expect_fail "a missing modules.* file" "linux-aurora files do not match the package mtree"
TEST_QKK_FAIL=linux-aurora:silent run_check
expect_fail "a pacman -Qkk that fails without a word" "pacman -Qkk linux-aurora failed"
# A DKMS module leaves depmod's maps rewritten: the mtree's size and checksum
# no longer match, and only depmod itself may vouch for them.
mkdir -p "$modules/kernel/drivers/net/xone"
printf 'fake module\n' >"$modules/kernel/drivers/net/xone/xone_dongle.ko"
TEST_QKK_FAIL=linux-aurora:depmod-size run_check
expect_fail "depmod maps that have not been regenerated after a DKMS module" "linux-aurora files do not match the package mtree"
depmod -b "$root" -o "$test_tmp/depmod" "$kver" 2>/dev/null
cp -a "$test_tmp/depmod/lib/modules/$kver/." "$modules/"
TEST_QKK_FAIL=linux-aurora:depmod-size run_check
expect_pass "depmod maps regenerated after a DKMS module"
printf 'corrupt\n' >>"$modules/modules.dep"
TEST_QKK_FAIL=linux-aurora:depmod-size run_check
expect_fail "a corrupted modules.dep beside a DKMS module" "linux-aurora files do not match the package mtree"
TEST_QKK_FAIL=linux-aurora:builtin-size run_check
expect_fail "modules.builtin, which depmod reads but does not write" "linux-aurora files do not match the package mtree"
unset TEST_QKK_FAIL

TEST_QKK_NODB=1 run_check
expect_pass "missing sync databases on a fresh image"
TEST_QKK_NODB=1 TEST_QKK_FAIL=linux-aurora run_check
expect_fail "altered files next to missing sync databases" "linux-aurora files do not match the package mtree"
pass "missing sync database warnings are not altered package files"

# A Limine Mac: the menu, UKI and Limine binary live on the ESP that
# /etc/default/limine names, the entry's rootflags follow the root
# filesystem, and the hash-verified UKI carries the installed kernel.
cat >"$stub_bin/objcopy" <<'SH'
#!/bin/bash
# Fixture UKIs are the kernel bytes followed by a marker: .linux is the file.
[[ $* == "-O binary --only-section=.linux "* ]] || exit 1
cp "$4" "$5"
SH
chmod +x "$stub_bin/objcopy"
limine_system() {
  local limine_esp=$1 fstab_row=$2 cmdline=$3 uki
  system linux-asahi
  mkdir -p "$root/var/lib/omarchy" "$root/etc" "$root/usr/share/limine" "$root$limine_esp/EFI/Linux" "$root$limine_esp/EFI/BOOT"
  # m1n1 sits on the system ESP, which on these Macs is the one Limine uses.
  [[ $limine_esp == /boot/efi ]] || mv "$esp/m1n1" "$root$limine_esp/m1n1"
  : >"$root/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="%s"\nENABLE_UKI=yes\n' "$limine_esp" >"$root/etc/default/limine"
  [[ -z $fstab_row ]] || printf '%s\n' "$fstab_row" >"$root/etc/fstab"
  printf 'LIMINE\n' >"$root/usr/share/limine/BOOTAA64.EFI"
  cp "$root/usr/share/limine/BOOTAA64.EFI" "$root$limine_esp/EFI/BOOT/BOOTAA64.EFI"
  uki="$root$limine_esp/EFI/Linux/omarchy_linux-asahi.efi"
  { cat "$modules/vmlinuz"; printf 'initrd\n'; } >"$uki"
  printf '/+Omarchy\n  //linux-asahi\n    protocol: efi\n    path: boot():/EFI/Linux/omarchy_linux-asahi.efi#%s\n    cmdline: %s\n' \
    "$(b2sum "$uki" | cut -d' ' -f1)" "$cmdline" >"$root$limine_esp/limine.conf"
  rm -f "$root/boot/grub/grub.cfg"
}

limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@,x-systemd.device-timeout=0 quiet'
run_check
expect_pass "a Limine Mac with its ESP at /boot/efi"
limine_system /boot 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
run_check
expect_pass "a Limine Mac with its ESP at /boot"
printf "ESP_PATH='/boot' # older installs\nENABLE_UKI=yes\n" >"$root/etc/default/limine"
run_check
expect_pass "a single-quoted ESP_PATH with a trailing comment"
rm "$root/boot/EFI/Linux/omarchy_linux-asahi.efi"
run_check
expect_fail "a Limine Mac missing its UKI on the /boot ESP" "/boot/EFI/Linux/omarchy_linux-asahi.efi (the Limine UKI) is missing"
pass "the Limine files are checked on the ESP /etc/default/limine names"

limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
printf 'stale' >>"$root/boot/efi/EFI/Linux/omarchy_linux-asahi.efi"
run_check
expect_fail "a UKI rebuilt after the menu" "does not match the hash in limine.conf"
limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
sed -i 's/#[0-9a-f]*$//' "$root/boot/efi/limine.conf"
run_check
expect_fail "an entry without a hash" "does not name a hash-verified omarchy_linux-asahi.efi"
limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
uki="$root/boot/efi/EFI/Linux/omarchy_linux-asahi.efi"
printf 'an older kernel\n' >"$uki"
sed -i "s/#[0-9a-f]*$/#$(b2sum "$uki" | cut -d' ' -f1)/" "$root/boot/efi/limine.conf"
run_check
expect_fail "a UKI from another kernel" "does not carry the installed $kver kernel"
# Without binutils the kernel comparison is skipped and said so; only
# observable where the host has no objcopy of its own.
if ! command -v objcopy >/dev/null 2>&1; then
  limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
  mv "$stub_bin/objcopy" "$test_tmp/objcopy"
  run_check
  mv "$test_tmp/objcopy" "$stub_bin/objcopy"
  expect_pass "a Limine Mac without binutils"
  grep -Fq "not checking the kernel inside the UKI" "$test_tmp/err" || fail "a skipped kernel check is named" "$(cat "$test_tmp/err")"
fi
pass "the Limine entry's hash and the UKI's kernel are checked"

limine_system /boot/efi 'UUID=r / ext4 rw,relatime 0 1' 'root=UUID=r rw quiet'
run_check
expect_pass "an ext4 root with no subvolume flag"
limine_system /boot/efi 'UUID=r / ext4 rw,relatime 0 1' 'root=UUID=r rw rootflags=subvol=@ quiet'
run_check
expect_fail "an ext4 root given subvol=" "selects rootflags=subvol=@, but the root filesystem is ext4"
limine_system /boot/efi 'UUID=r / btrfs rw,subvol=@root 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
run_check
expect_fail "a btrfs root booted from another subvolume" "does not select rootflags=subvol=@root"
limine_system /boot/efi 'UUID=r / btrfs rw,subvol=@root 0 0' 'root=UUID=r rw rootflags=subvol=@root quiet'
run_check
expect_pass "a btrfs root booted from its own subvolume"
limine_system /boot/efi '' 'root=UUID=r rw quiet'
run_check
expect_fail "no fstab row (Omarchy's btrfs @) and no subvolume flag" "does not select rootflags=subvol=@"
pass "the Limine entry's rootflags follow the root filesystem"

# U-Boot boots the loader on the system ESP the device tree names, so the
# Limine files checked on ESP_PATH must be the ones there.
limine_on_system_esp() {
  limine_system /boot/efi 'UUID=r / btrfs rw,subvol=/@ 0 0' 'root=UUID=r rw rootflags=subvol=@ quiet'
  mkdir -p "$root/proc/device-tree/chosen" "$existing"
  printf '%s\0' "$partuuid" >"$root/proc/device-tree/chosen/asahi,efi-system-partition"
  cp -a "$esp/." "$existing/"
}
limine_on_system_esp
TEST_EXISTING_MOUNT="$existing" run_check
expect_pass "a Limine Mac whose system ESP holds the Limine files ESP_PATH names"
limine_on_system_esp
rm -rf "$existing/EFI" "$existing/limine.conf"
TEST_EXISTING_MOUNT="$existing" run_check
expect_fail "a Limine Mac whose ESP_PATH is another ESP than the system one" "/boot/efi/EFI/BOOT/BOOTAA64.EFI is not the one on the system ESP (PARTUUID=$partuuid), which U-Boot boots"
limine_on_system_esp
printf 'GRUB\n' >"$existing/EFI/BOOT/BOOTAA64.EFI"
TEST_EXISTING_MOUNT="$existing" run_check
expect_fail "a system ESP whose loader slot is not the checked Limine" "/boot/efi/EFI/BOOT/BOOTAA64.EFI is not the one on the system ESP"
limine_on_system_esp
printf 'older\n' >>"$existing/EFI/Linux/omarchy_linux-asahi.efi"
TEST_EXISTING_MOUNT="$existing" run_check
expect_fail "a system ESP with another UKI" "/boot/efi/EFI/Linux/omarchy_linux-asahi.efi is not the one on the system ESP"
limine_on_system_esp
sed -i 's/quiet$/quiet splash/' "$existing/limine.conf"
TEST_EXISTING_MOUNT="$existing" run_check
expect_fail "a system ESP with another menu" "/boot/efi/limine.conf is not the one on the system ESP"
limine_on_system_esp
printf 'M1N1_UPDATE_DISABLED=1\n' >"$root/etc/default/update-m1n1"
printf 'GRUB\n' >"$existing/EFI/BOOT/BOOTAA64.EFI"
TEST_EXISTING_MOUNT="$existing" run_check --boot-chain
expect_fail "an m1n1 left to its owner beside another loader on the system ESP" "/boot/efi/EFI/BOOT/BOOTAA64.EFI is not the one on the system ESP"
pass "a Limine Mac boots the Limine, menu and UKI on the system ESP"
