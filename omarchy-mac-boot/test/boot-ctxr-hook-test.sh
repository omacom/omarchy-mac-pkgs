#!/bin/bash
# 97-omarchy-mac-boot-ctxr.hook: an M4-and-later Mac's m1n1/boot-ctxr.bin is
# rebuilt with update-m1n1 like m1n1/boot.bin, kept within aura's 16 MiB slot,
# and every other Mac is left alone.

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

script=$ROOT/files/usr/share/libalpm/scripts/omarchy-mac-boot-ctxr
hook=$ROOT/files/usr/share/libalpm/hooks/97-omarchy-mac-boot-ctxr.hook
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
esp=$tmp/esp
mkdir -p "$esp/m1n1" "$tmp/bin"
export OMARCHY_MAC_BOOT_CTXR_ESP=$esp
export OMARCHY_MAC_BOOT_CTXR_UPDATE_M1N1=$tmp/bin/update-m1n1

# A stand-in update-m1n1: writes $SIZE bytes of $BYTE to its target, as the
# real one rebuilds TARGET from m1n1, the device trees and U-Boot, or fails.
cat >"$tmp/bin/update-m1n1" <<'EOF'
#!/bin/bash
echo "$1" >>"$CALLS"
[[ ${FAIL:-} != 1 ]] || exit 1
head -c "$SIZE" /dev/zero | tr '\0' "$BYTE" >"$1"
EOF
chmod +x "$tmp/bin/update-m1n1"
export CALLS=$tmp/calls

# Every other Mac: no boot-ctxr.bin, nothing runs.
: >"$CALLS"
SIZE=10 BYTE=n bash "$script" || fail "a Mac without boot-ctxr.bin fails the hook"
[[ ! -s $CALLS && ! -e $esp/m1n1/boot-ctxr.bin ]] || fail "a Mac without boot-ctxr.bin gets one"
pass "a Mac without the confined Stage 2 is left alone"

# An M4: rebuilt in place by update-m1n1, with the boot-ctxr.bin path as its target.
printf 'old image' >"$esp/m1n1/boot-ctxr.bin"
: >"$CALLS"
SIZE=4096 BYTE=k bash "$script" || fail "an M4's boot-ctxr.bin is not rebuilt"
[[ $(<"$CALLS") == "$esp/m1n1/boot-ctxr.bin" ]] || fail "update-m1n1 is not asked for boot-ctxr.bin: $(<"$CALLS")"
[[ $(stat -c %s "$esp/m1n1/boot-ctxr.bin") == 4096 ]] || fail "boot-ctxr.bin is not the rebuilt image"
[[ -z $(find "$esp/m1n1" -name '.boot-ctxr.*') ]] || fail "the saved copy is left on the ESP"
pass "an M4's boot-ctxr.bin is rebuilt by update-m1n1"

# An image over the 16 MiB slot, or a failed update-m1n1, keeps the previous one.
printf 'good image' >"$esp/m1n1/boot-ctxr.bin"
if SIZE=$(( (16 << 20) + 1 )) BYTE=x bash "$script" 2>"$tmp/err"; then
  fail "an image over the 16 MiB slot is accepted"
fi
[[ $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "an oversized image replaced boot-ctxr.bin"
grep -q "16 MiB slot" "$tmp/err" || fail "the refusal does not name the slot: $(<"$tmp/err")"
if FAIL=1 SIZE=10 BYTE=f bash "$script" 2>"$tmp/err"; then
  fail "a failed update-m1n1 passes"
fi
[[ $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "a failed update-m1n1 changed boot-ctxr.bin"
[[ -z $(find "$esp/m1n1" -name '.boot-ctxr.*') ]] || fail "the saved copy is left on the ESP"
pass "an oversized image or a failed update-m1n1 keeps the previous boot-ctxr.bin"

# A link is never followed.
rm "$esp/m1n1/boot-ctxr.bin"
ln -s /dev/null "$esp/m1n1/boot-ctxr.bin"
: >"$CALLS"
SIZE=10 BYTE=l bash "$script" || fail "a linked boot-ctxr.bin fails the hook"
[[ ! -s $CALLS ]] || fail "a linked boot-ctxr.bin is rebuilt"
pass "a linked boot-ctxr.bin is left alone"

# The hook runs after 95-m1n1-install.hook (and 95/96 here), on the same paths, and the script.
[[ $(basename "$hook") > 96-omarchy-mac-m3-air.hook && $(basename "$hook") > 95-m1n1-install.hook ]] ||
  fail "the hook does not sort after the m1n1 hooks"
for target in 'usr/lib/modules/*/dtbs/*' 'usr/lib/asahi-boot/*' 'usr/lib/omarchy-mac-boot/dtb-overlays/*/*.dtbo'; do
  grep -Fxq "Target = $target" "$hook" || fail "the hook misses $target"
done
grep -Fxq "Exec = /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$hook" || fail "the hook does not run the script"
[[ -x $script ]] || fail "the script is not executable"
pass "the hook follows the m1n1 hooks on their paths"
