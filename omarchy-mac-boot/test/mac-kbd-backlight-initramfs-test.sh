#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# 92-omarchy-mac-kbd-backlight.conf adds pwm-apple only where the target
# kernel has it as a module, and bundles the backlight rule only when present.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dropin=$ROOT/files/etc/mkinitcpio.conf.d/92-omarchy-mac-kbd-backlight.conf
rules=$ROOT/files/usr/lib/udev/rules.d/90-omarchy-mac-kbd-backlight.rules
mkdir -p "$work/bin"
cat >"$work/bin/modinfo" <<'SH'
#!/bin/sh
[ "$2" = "$EXPECTED_KERNEL" ] && [ "$5" = pwm-apple ] || exit 64
case $MODINFO in
  module) echo /lib/modules/k/kernel/drivers/pwm/pwm-apple.ko ;;
  builtin) echo '(builtin)' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/bin/modinfo"
# The drop-in names the installed rule path; each case points it at a staged one.
staged() {
  sed "s#/usr/lib/udev/rules.d/90-omarchy-mac-kbd-backlight.rules#$2#g" "$dropin" >"$work/dropin"
  MODINFO=$1 EXPECTED_KERNEL=target-kernel PATH="$work/bin:$PATH" bash -c '
    MODULES=(btrfs)
    FILES=()
    KERNELVERSION=target-kernel
    source "$1"
    printf "%s|%s|%s|%s\n" "$?" "${MODULES[*]}" "${FILES[*]}" "${_omarchy_mac_kbd_pwm_path-unset}"
  ' _ "$work/dropin"
}
[[ $(staged module "$rules") == "0|btrfs pwm-apple|$rules|unset" ]] || fail 'a module pwm-apple and the rule join the initramfs' "$(staged module "$rules")"
[[ $(staged builtin "$rules") == "0|btrfs|$rules|unset" ]] || fail 'a built-in pwm-apple is left out' "$(staged builtin "$rules")"
[[ $(staged none "$rules") == "0|btrfs|$rules|unset" ]] || fail 'a kernel without pwm-apple is left out' "$(staged none "$rules")"
[[ $(staged module "$work/absent.rules") == '0|btrfs pwm-apple||unset' ]] || fail 'a missing rule is not bundled' "$(staged module "$work/absent.rules")"
pass 'pwm-apple joins the initramfs only as a module, the rule only when installed'

if command -v udevadm >/dev/null; then
  udevadm verify --no-summary "$rules" || fail 'the backlight rule parses'
  pass 'the backlight rule parses'
fi
