#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The built-in keyboard gets the Print and keyboard backlight keys Omarchy
# binds, through a udev hwdb remap that only matches Apple's SPI and MTP
# keyboards.
"$ROOT/install" "$work/root"
hwdb=$work/root/usr/lib/udev/hwdb.d/90-omarchy-mac-keyboard.hwdb
[[ -f $hwdb ]] || fail 'the keyboard remap is staged in the vendor hwdb directory'
pass 'the keyboard remap is staged'

command -v systemd-hwdb >/dev/null || { pass 'systemd-hwdb is not installed; remap lookups skipped'; exit 0; }
systemd-hwdb --root="$work/root" update --usr || fail 'the remap compiles'
lookup() { systemd-hwdb --root="$work/root" query "evdev:name:$1:phys:spi0:ev:120013"; }
for name in 'Apple SPI Keyboard' 'Apple MTP keyboard' 'Apple MTP Keyboard'; do
  keys=$(lookup "$name")
  for expected in KEYBOARD_KEY_7003d=sysrq KEYBOARD_KEY_7003e=kbdillumdown KEYBOARD_KEY_7003f=kbdillumup; do
    grep -Fxq "$expected" <<<"$keys" || fail "$name gets $expected" "$keys"
  done
done
for name in 'Apple Inc. Magic Keyboard' 'Keychron K2' 'Apple SPI Trackpad'; do
  [[ -z $(lookup "$name") ]] || fail "$name keeps its keys" "$(lookup "$name")"
done
pass 'only the built-in keyboard gets Print on F4 and the backlight on F5 and F6'
