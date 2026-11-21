#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# 92-omarchy-mac-display-gate.conf adds the display gate's modules to the
# initramfs, each only where the target kernel has it as a module, so a
# built-in or missing driver never fails mkinitcpio, and never anything else.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dropin=$ROOT/files/etc/mkinitcpio.conf.d/92-omarchy-mac-display-gate.conf
hook=$ROOT/files/usr/share/libalpm/hooks/91-omarchy-mac-boot-initramfs.hook
[[ -f $dropin ]] || fail "the display gate drop-in is missing"
mkdir -p "$work/bin"
# MODINFO_MODULES lists the modules, MODINFO_BUILTIN the built-ins, of the target kernel.
cat >"$work/bin/modinfo" <<'SH'
#!/bin/sh
[ "$1" = -k ] && [ "$2" = "$EXPECTED_KERNEL" ] && [ "$3" = -F ] && [ "$4" = filename ] || exit 64
for name in $MODINFO_MODULES; do [ "$name" = "$5" ] && { echo "/lib/modules/k/kernel/$5.ko.zst"; exit 0; }; done
for name in $MODINFO_BUILTIN; do [ "$name" = "$5" ] && { echo '(builtin)'; exit 0; }; done
exit 1
SH
chmod +x "$work/bin/modinfo"
modules() {
  MODINFO_MODULES=$1 MODINFO_BUILTIN=${2:-} EXPECTED_KERNEL=target-kernel PATH="$work/bin:$PATH" bash -c '
    MODULES=(btrfs)
    KERNELVERSION=target-kernel
    source "$1"
    printf "%s|%s|%s|%s\n" "$?" "${MODULES[*]}" "${_omarchy_mac_display_module-unset}" "${_omarchy_mac_display_path-unset}"
  ' _ "$dropin"
}
all="phy-apple-t6040-usb2 mux-apple-display-crossbar atc-t6050-dp phy-apple-atc phy-apple-dptx"
[[ $(modules "$all") == "0|btrfs $all|unset|unset" ]] || fail "the display gate's modules join the initramfs" "$(modules "$all")"
pass "an M4 kernel's display gate modules join the initramfs"
[[ $(modules "mux-apple-display-crossbar phy-apple-atc") == "0|btrfs mux-apple-display-crossbar phy-apple-atc|unset|unset" ]] ||
  fail "a kernel without the M4 PHY still gets the others" "$(modules "mux-apple-display-crossbar phy-apple-atc")"
[[ $(modules "" "$all") == "0|btrfs|unset|unset" ]] || fail "built-in drivers are left out" "$(modules "" "$all")"
[[ $(modules "") == "0|btrfs|unset|unset" ]] || fail "a kernel with none of them is left out" "$(modules "")"
pass "only modules the target kernel ships are added, and built-ins are left out"
grep -Fxq "Target = etc/mkinitcpio.conf.d/92-omarchy-mac-display-gate.conf" "$hook" ||
  fail "the initramfs hook does not rebuild when the drop-in changes"
pass "the initramfs is rebuilt when the display gate drop-in changes"
