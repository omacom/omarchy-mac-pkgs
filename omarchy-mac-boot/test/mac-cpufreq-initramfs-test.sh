#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# 92-omarchy-mac-cpufreq.conf adds apple_soc_cpufreq to the initramfs only where
# the target kernel has it as a module, so a built-in or missing driver never
# fails mkinitcpio, and never anything else.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dropin=$ROOT/files/etc/mkinitcpio.conf.d/92-omarchy-mac-cpufreq.conf
mkdir -p "$work/bin"
cat >"$work/bin/modinfo" <<'SH'
#!/bin/sh
[ "$2" = "$EXPECTED_KERNEL" ] && [ "$5" = apple_soc_cpufreq ] || exit 64
case $MODINFO in
  module) echo /lib/modules/k/kernel/drivers/cpufreq/apple-soc-cpufreq.ko ;;
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
    printf "%s|%s|%s\n" "$?" "${MODULES[*]}" "${_omarchy_mac_cpufreq_path-unset}"
  ' _ "$dropin"
}
[[ $(modules module) == '0|btrfs apple_soc_cpufreq|unset' ]] || fail 'a module apple_soc_cpufreq joins the initramfs' "$(modules module)"
[[ $(modules builtin) == '0|btrfs|unset' ]] || fail 'a built-in apple_soc_cpufreq is left out' "$(modules builtin)"
[[ $(modules none) == '0|btrfs|unset' ]] || fail 'a kernel without apple_soc_cpufreq is left out' "$(modules none)"
pass 'apple_soc_cpufreq joins the initramfs only as a module of the target kernel'
