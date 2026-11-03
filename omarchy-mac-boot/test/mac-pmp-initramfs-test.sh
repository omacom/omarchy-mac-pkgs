#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# 92-omarchy-mac-pmp.conf adds apple_pmp to the initramfs only where the
# target kernel has it as a module, so a built-in or missing driver never
# fails mkinitcpio, and never anything else.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dropin=$ROOT/files/etc/mkinitcpio.conf.d/92-omarchy-mac-pmp.conf
mkdir -p "$work/bin"
cat >"$work/bin/modinfo" <<'SH'
#!/bin/sh
[ "$2" = "$EXPECTED_KERNEL" ] && [ "$5" = apple_pmp ] || exit 64
case $MODINFO in
  module) echo /lib/modules/k/kernel/drivers/soc/apple/apple-pmp.ko ;;
  builtin) echo '(builtin)' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/bin/modinfo"
modules() {
  MODINFO=$1 EXPECTED_KERNEL=target-kernel PATH="$work/bin:$PATH" bash -c '
    MODULES=(btrfs)
    KERNELVERSION=target-kernel
    source "$1"
    printf "%s|%s|%s\n" "$?" "${MODULES[*]}" "${_omarchy_mac_pmp_path-unset}"
  ' _ "$dropin"
}
[[ $(modules module) == '0|btrfs apple_pmp|unset' ]] || fail 'a module apple_pmp joins the initramfs' "$(modules module)"
[[ $(modules builtin) == '0|btrfs|unset' ]] || fail 'a built-in apple_pmp is left out' "$(modules builtin)"
[[ $(modules none) == '0|btrfs|unset' ]] || fail 'a kernel without apple_pmp is left out' "$(modules none)"
pass 'apple_pmp joins the initramfs only as a module of the target kernel'
