#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# setup/m1n1-display.sh writes the M3 Air display opt-in into m1n1.conf and
# rebuilds boot.bin, only on a J613 or J615 whose m1n1-aurora has the gate.
command -v vercmp >/dev/null || { printf 'skip - m1n1 display default: vercmp is not installed\n'; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub=$work/bin
mkdir -p "$stub"
printf '#!/bin/bash\n[[ ${NOT_APPLE:-} != 1 ]]\n' >"$stub/omarchy-hw-apple-silicon"
# A vercmp that fails after printing a number, prints text with a number in it, or prints nothing.
fake_vercmp=$work/fake-vercmp
mkdir -p "$fake_vercmp"
cat >"$fake_vercmp/vercmp" <<'SH'
#!/bin/bash
case $VERCMP in
  fails) echo 1; exit 1 ;;
  garbage) echo 'error: 2 is not a version' ;;
  empty) ;;
esac
SH
chmod +x "$fake_vercmp/vercmp"
cat >"$stub/pacman" <<'SH'
#!/bin/bash
[[ $1 == -Q && $2 == m1n1-aurora && -n ${M1N1_VERSION:-} ]] || exit 1
echo "${M1N1_PACKAGE:-m1n1-aurora} $M1N1_VERSION"
SH
cat >"$stub/sudo" <<'SH'
#!/bin/bash
[[ ${WRITE_FAILS:-} == 1 && $1 == install && $2 == -D ]] && { rm -f "${@: -1}"; exit 1; }
exec "$@"
SH
cat >"$stub/update-m1n1" <<'SH'
#!/bin/bash
echo update-m1n1 >>"$CALLS"
[[ ${UPDATE_FAILS:-} != 1 ]]
SH
chmod +x "$stub"/*
export CALLS=$work/calls
mkdir -p "$work/run-systemd"

# machine COMPATIBLE...: a device tree root compatible list.
machine() { printf '%s\0' "$@" >"$work/compatible"; }
run() {
  : >"$CALLS"
  PATH="${VERCMP:+$fake_vercmp:}$stub:$PATH" OMARCHY_DEVICE_TREE_COMPATIBLE=$work/compatible OMARCHY_M1N1_CONF=$work/etc/m1n1.conf \
    OMARCHY_SYSTEMD_RUN=${SYSTEMD_RUN-$work/run-systemd} \
    OMARCHY_M1N1_T8122_DCP_MINIMUM=${MINIMUM-1.6.1.aurora21-1} M1N1_VERSION=${VERSION-1.6.1.aurora21-1} \
    bash -c 'source "$1"' _ "$ROOT/setup/m1n1-display.sh" >"$work/out" 2>&1
}
conf() { cat "$work/etc/m1n1.conf" 2>/dev/null || echo absent; }

machine apple,j613 apple,t8122 apple,arm-platform
run || fail 'a fresh M3 Air takes the display default' "$(cat "$work/out")"
grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" && [[ $(<"$CALLS") == update-m1n1 ]] ||
  fail 'the opt-in is written and boot.bin rebuilt' "$(conf) / $(cat "$CALLS")"
[[ $(stat -c %a "$work/etc/m1n1.conf") == 644 ]] || fail 'm1n1.conf is world-readable, as update-m1n1 reads it'
before=$(conf)
run && [[ $(conf) == "$before" && ! -s $CALLS ]] || fail 'a rerun changes nothing and rebuilds nothing'
machine apple,j615 apple,t8122 apple,arm-platform
rm -rf "$work/etc"
run && grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" || fail 'the 15-inch M3 Air takes it too'
pass 'an M3 Air gets the native display in m1n1.conf and boot.bin, once'

# The owner's own m1n1.conf lines stay, and their own choice for the display wins.
mkdir -p "$work/etc"
printf 'display=1920x1080\nchosen.asahi,other=1' >"$work/etc/m1n1.conf"
run || fail 'an M3 Air with its own m1n1.conf takes the default'
[[ $(head -n 2 "$work/etc/m1n1.conf") == $'display=1920x1080\nchosen.asahi,other=1' ]] &&
  grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" || fail 'the owner lines stay, and a last line without a newline is not joined' "$(conf)"
printf 'chosen.asahi,t8122-dcp=0\n' >"$work/etc/m1n1.conf"
run && [[ $(conf) == 'chosen.asahi,t8122-dcp=0' && ! -s $CALLS ]] || fail "the owner's own choice is never overwritten" "$(conf)"
printf 'chosenXasahi,t8122-dcp=0\n' >"$work/etc/m1n1.conf"
run && grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" || fail 'only the exact key counts as the owner line, not a near miss' "$(conf)"
pass "the owner's m1n1.conf lines and choice are kept"

# The hard gate: an m1n1 without the opt-in gate black-screens with the line.
check_untouched() {
  rm -rf "$work/etc"
  run || fail "$1: still succeeds"
  [[ $(conf) == absent && ! -s $CALLS ]] || fail "$1" "$(conf) $(cat "$CALLS")"
}
machine apple,j613 apple,t8122 apple,arm-platform
VERSION=1.6.1.aurora20-3 check_untouched 'an older m1n1-aurora gets nothing written'
grep -q predates "$work/out" || fail 'an older m1n1-aurora is named as older, not as uncomparable' "$(cat "$work/out")"
VERSION= check_untouched 'without m1n1-aurora nothing is written'
MINIMUM= check_untouched 'until the minimum is known nothing is written'
M1N1_PACKAGE=m1n1-other check_untouched 'a package that only provides m1n1-aurora is not taken for it'
SYSTEMD_RUN=$work/no-such-run check_untouched "an image build's chroot, with no booted systemd, gets nothing written"
for result in fails garbage empty; do
  VERCMP=$result check_untouched "a vercmp that $result writes nothing: the gate fails closed"
done
NOT_APPLE=1 check_untouched 'off Apple Silicon nothing is written'
OMARCHY_MAC_IMAGE_BUILD=1 check_untouched 'an image build writes nothing'
machine apple,j613 apple,t8112 apple,arm-platform
check_untouched 'a J613 board name on another SoC is left alone'
machine apple,j504 apple,t8122 apple,arm-platform
check_untouched 'another T8122 Mac is left alone'
machine apple,j414c apple,t6021 apple,arm-platform
check_untouched 'an M2 Max is left alone'
grep -Fxq '  m1n1_t8122_dcp_minimum=' "$ROOT/setup/m1n1-display.sh" ||
  fail 'the packaged minimum stays empty until the gated m1n1-aurora is published'
pass 'nothing is written without a gated m1n1-aurora on an M3 Air'

# A failed rebuild leaves m1n1.conf as it was, so the boot check stays consistent.
machine apple,j613 apple,t8122 apple,arm-platform
rm -rf "$work/etc"
UPDATE_FAILS=1 run || fail 'a failed update-m1n1 warns but never fails the setup'
[[ $(conf) == absent ]] && grep -q 'stays off' "$work/out" || fail 'a new m1n1.conf is removed again after a failed rebuild, and it says so' "$(conf)"
mkdir -p "$work/etc" && printf 'display=1920x1080' >"$work/etc/m1n1.conf"
cp "$work/etc/m1n1.conf" "$work/original"
UPDATE_FAILS=1 run || fail 'a failed update-m1n1 warns but never fails the setup'
cmp -s "$work/etc/m1n1.conf" "$work/original" || fail "the owner's m1n1.conf is back byte for byte, a last line without a newline included" "$(od -c "$work/etc/m1n1.conf" | head -2)"
mkdir -p "$work/etc" && printf 'display=1920x1080\n' >"$work/etc/m1n1.conf"
cp "$work/etc/m1n1.conf" "$work/original"
WRITE_FAILS=1 run || fail 'a failed first write never fails the setup'
cmp -s "$work/etc/m1n1.conf" "$work/original" && [[ ! -s $CALLS ]] ||
  fail "a failed first write puts the owner's m1n1.conf back and rebuilds nothing" "$(conf)"
cat >"$stub/sudo" <<'SH'
#!/bin/bash
[[ ${RESTORE_FAILS:-} == 1 && $1 == install && $2 == -m ]] && exit 1
exec "$@"
SH
UPDATE_FAILS=1 RESTORE_FAILS=1 run || fail 'a failed restore still never fails the setup'
grep -q 'could not be put back' "$work/out" || fail 'a failed restore says so instead of claiming m1n1.conf is back' "$(cat "$work/out")"
pass 'a failed rebuild puts m1n1.conf back exactly, and the setup carries on'
