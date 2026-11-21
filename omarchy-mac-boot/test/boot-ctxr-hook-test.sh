#!/bin/bash
# 97-omarchy-mac-boot-ctxr.hook: an M4-and-later Mac's m1n1/boot-ctxr.bin is rebuilt with
# update-m1n1 into a staging name, held to aura's 16 MiB slot, and moved into place.

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
export OMARCHY_MAC_BOOT_CTXR_CONFIG=$tmp/update-m1n1.conf
export CALLS=$tmp/calls

# A stand-in for asahi-scripts' update-m1n1, in its order: the configuration is sourced
# first (M1N1_UPDATE_DISABLED exits 0, a TARGET there wins over $1), then TARGET.new, then mv.
cat >"$tmp/bin/update-m1n1" <<'EOF'
#!/bin/bash
[ -e "$OMARCHY_MAC_BOOT_CTXR_CONFIG" ] && . "$OMARCHY_MAC_BOOT_CTXR_CONFIG"
[ -n "${M1N1_UPDATE_DISABLED:-}" ] && exit 0
: ${TARGET:="$1"}
echo "$TARGET" >>"$CALLS"
[[ ${FAIL:-} != 1 ]] || exit 1
[[ ${SKIP_WRITE:-} != 1 ]] || exit 0
head -c "$SIZE" /dev/zero | tr '\0' "$BYTE" >"$TARGET.new"
/usr/bin/mv -f "$TARGET.new" "$TARGET"
EOF
chmod +x "$tmp/bin/update-m1n1"
leftovers() { find "$esp/m1n1" -name '.boot-ctxr.*'; }

# Every other Mac: no boot-ctxr.bin, nothing runs.
: >"$CALLS"
SIZE=10 BYTE=n bash "$script" || fail "a Mac without boot-ctxr.bin fails the hook"
[[ ! -s $CALLS && ! -e $esp/m1n1/boot-ctxr.bin ]] || fail "a Mac without boot-ctxr.bin gets one"
pass "a Mac without the confined Stage 2 is left alone"

# An M4: built into a staging name on the ESP, then moved into place, the previous kept as .old.
printf 'old image' >"$esp/m1n1/boot-ctxr.bin"
: >"$CALLS"
SIZE=4096 BYTE=k bash "$script" >/dev/null || fail "an M4's boot-ctxr.bin is not rebuilt"
[[ $(<"$CALLS") == "$esp/m1n1/.boot-ctxr."* ]] || fail "update-m1n1 is not given a staging name: $(<"$CALLS")"
[[ $(stat -c %s "$esp/m1n1/boot-ctxr.bin") == 4096 ]] || fail "boot-ctxr.bin is not the rebuilt image"
[[ $(<"$esp/m1n1/boot-ctxr.bin.old") == "old image" ]] || fail "the previous image is not kept as boot-ctxr.bin.old"
[[ -z $(leftovers) ]] || fail "the staging name is left on the ESP: $(leftovers)"
pass "an M4's boot-ctxr.bin is staged, rebuilt by update-m1n1 and moved into place"

# Each failure leaves the live file untouched, cleans up, and says so.
refuse() {
  local why=$1 expect=$2
  shift 2
  printf 'good image' >"$esp/m1n1/boot-ctxr.bin"
  if env "$@" bash "$script" 2>"$tmp/err" >/dev/null; then fail "$why passes"; fi
  [[ $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "$why changed boot-ctxr.bin"
  grep -q "$expect" "$tmp/err" || fail "$why is not reported: $(<"$tmp/err")"
  [[ -z $(leftovers) ]] || fail "$why leaves the staging name on the ESP: $(leftovers)"
}
refuse "an image over the 16 MiB slot" "16 MiB slot" SIZE=$(( (16 << 20) + 1 )) BYTE=x
refuse "a failed update-m1n1" "update-m1n1 failed" FAIL=1 SIZE=10 BYTE=f
refuse "an update-m1n1 that wrote nothing" "did not write the staged image" SKIP_WRITE=1 SIZE=10 BYTE=s
pass "an oversized image, a failed update-m1n1 or a missing staged image keeps boot-ctxr.bin"

# A move into place that fails is reported, and boot-ctxr.bin is unchanged.
printf 'good image' >"$esp/m1n1/boot-ctxr.bin"
printf '#!/bin/bash\nexit 1\n' >"$tmp/bin/mv"
chmod +x "$tmp/bin/mv"
if PATH=$tmp/bin:$PATH SIZE=10 BYTE=m bash "$script" 2>"$tmp/err" >/dev/null; then fail "a failed move passes"; fi
rm "$tmp/bin/mv"
[[ $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "a failed move changed boot-ctxr.bin"
grep -q "could not move" "$tmp/err" || fail "a failed move is not reported: $(<"$tmp/err")"
[[ -z $(leftovers) ]] || fail "a failed move leaves the staging name on the ESP: $(leftovers)"
pass "a move that fails is reported and boot-ctxr.bin is unchanged"

# The configuration: M1N1_UPDATE_DISABLED stands down with a note; a TARGET there is refused.
printf 'good image' >"$esp/m1n1/boot-ctxr.bin"
printf 'M1N1_UPDATE_DISABLED=1\n' >"$OMARCHY_MAC_BOOT_CTXR_CONFIG"
: >"$CALLS"
SIZE=10 BYTE=d bash "$script" 2>"$tmp/err" || fail "M1N1_UPDATE_DISABLED fails the hook"
[[ ! -s $CALLS && $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "M1N1_UPDATE_DISABLED still rebuilds"
grep -q "M1N1_UPDATE_DISABLED is set" "$tmp/err" || fail "standing down is silent"
printf 'TARGET=/boot/efi/m1n1/boot.bin\n' >"$OMARCHY_MAC_BOOT_CTXR_CONFIG"
: >"$CALLS"
if SIZE=10 BYTE=t bash "$script" 2>"$tmp/err"; then fail "a configured TARGET passes"; fi
[[ ! -s $CALLS && $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "a configured TARGET still runs update-m1n1"
grep -q "sets TARGET=/boot/efi/m1n1/boot.bin" "$tmp/err" || fail "a configured TARGET is not reported: $(<"$tmp/err")"
rm "$OMARCHY_MAC_BOOT_CTXR_CONFIG"
pass "M1N1_UPDATE_DISABLED stands down with a note and a configured TARGET is refused"

# Aurora's update-m1n1 keeps boot-ctxr.bin itself: stand down.
printf 'good image' >"$esp/m1n1/boot-ctxr.bin"
cp "$tmp/bin/update-m1n1" "$tmp/stock"
printf '# AURORA_BOOTCHAIN\n' >>"$tmp/bin/update-m1n1"
: >"$CALLS"
SIZE=10 BYTE=a bash "$script" 2>"$tmp/err" || fail "Aurora's update-m1n1 fails the hook"
[[ ! -s $CALLS && $(<"$esp/m1n1/boot-ctxr.bin") == "good image" ]] || fail "the hook runs over Aurora's bootchain"
grep -q "is Aurora's" "$tmp/err" || fail "standing down for Aurora is silent"
cp "$tmp/stock" "$tmp/bin/update-m1n1"
pass "an Aurora update-m1n1, which keeps boot-ctxr.bin itself, is left to it"

# A link is never followed.
rm "$esp/m1n1/boot-ctxr.bin"
ln -s /dev/null "$esp/m1n1/boot-ctxr.bin"
: >"$CALLS"
SIZE=10 BYTE=l bash "$script" || fail "a linked boot-ctxr.bin fails the hook"
[[ ! -s $CALLS ]] || fail "a linked boot-ctxr.bin is rebuilt"
pass "a linked boot-ctxr.bin is left alone"

# The hook: after the m1n1 hooks, on 95-m1n1-install.hook's paths and operations (Install,
# Upgrade), on the overlay paths with Remove too, and on an update of this package.
[[ $(basename "$hook") > 96-omarchy-mac-m3-air.hook && $(basename "$hook") > 95-m1n1-install.hook ]] ||
  fail "the hook does not sort after the m1n1 hooks"
triggers=$(awk '/^\[Trigger\]/{n++} /^(Type|Operation|Target) = /{print n "|" $0}' "$hook")
expected="1|Type = Path
1|Operation = Install
1|Operation = Upgrade
1|Target = usr/lib/modules/*/dtbs/*
1|Target = usr/lib/asahi-boot/*
2|Type = Path
2|Operation = Install
2|Operation = Upgrade
2|Operation = Remove
2|Target = usr/lib/omarchy-mac-boot/dtb-overlays/*/*.dtbo
3|Type = Package
3|Operation = Install
3|Operation = Upgrade
3|Target = omarchy-mac-boot"
[[ $triggers == "$expected" ]] || fail "the hook's triggers are not the m1n1 hooks' paths and operations" "$triggers"
overlay_ops=$(awk '/^Operation = /{print $3}' "$ROOT/files/usr/share/libalpm/hooks/95-omarchy-mac-dtb-overlays.hook" | paste -sd' ')
[[ $overlay_ops == "Install Upgrade Remove" ]] || fail "95-omarchy-mac-dtb-overlays.hook's operations changed: $overlay_ops"
grep -Fxq "Exec = /usr/share/libalpm/scripts/omarchy-mac-boot-ctxr" "$hook" || fail "the hook does not run the script"
[[ -x $script ]] || fail "the script is not executable"
pass "the hook follows the m1n1 hooks on their paths and operations"
