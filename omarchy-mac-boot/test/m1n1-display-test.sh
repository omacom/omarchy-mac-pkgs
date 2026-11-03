#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# setup/m1n1-display.sh writes the M3 Air display and GPU switches into m1n1.conf
# and rebuilds boot.bin, only on a J613 or J615 whose m1n1-aurora has the gate.
command -v vercmp >/dev/null || { printf 'skip - m1n1 display default: vercmp is not installed\n'; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub=$work/bin
mkdir -p "$stub"
printf '#!/bin/bash\n[[ ${NOT_APPLE:-} != 1 ]]\n' >"$stub/omarchy-hw-apple-silicon"
# arch-chroot bind-mounts the host's /run: only systemd-detect-virt --chroot tells.
printf '#!/bin/bash\n[[ $* == "--quiet --chroot" && ${CHROOT:-} == 1 ]]\n' >"$stub/systemd-detect-virt"
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
    OMARCHY_M1N1_M3_DEFAULTS_MINIMUM=${DEFAULTS-99.0-1} \
    bash -c '[[ -z ${PACKAGED:-} ]] || unset OMARCHY_M1N1_T8122_DCP_MINIMUM
      [[ -z ${PACKAGED_DEFAULTS:-} ]] || unset OMARCHY_M1N1_M3_DEFAULTS_MINIMUM
      [[ -z ${FILE_BLOCKS:-} ]] || { trap "" XFSZ; ulimit -f "$FILE_BLOCKS"; }
      source "$1"' _ "$ROOT/setup/m1n1-display.sh" >"$work/out" 2>&1
}
conf() { cat "$work/etc/m1n1.conf" 2>/dev/null || echo absent; }
switches=("chosen.asahi,t8122-dcp=1" "chosen.asahi,t8122-gpu=1" "chosen.asahi,t8122-gpu-power-standin=1" "chosen.asahi,t8122-gpu-fuse-leakage=1")
# has_switches LINE...: m1n1.conf has each line exactly once.
has_switches() {
  local line
  for line in "$@"; do
    (( $(grep -Fxc "$line" "$work/etc/m1n1.conf" 2>/dev/null) == 1 )) || return 1
  done
}

machine apple,j613 apple,t8122 apple,arm-platform
run || fail 'a fresh M3 Air takes the display default' "$(cat "$work/out")"
has_switches "${switches[@]}" && [[ $(<"$CALLS") == update-m1n1 ]] ||
  fail 'the display, GPU and power handoff switches are written and boot.bin rebuilt once' "$(conf) / $(cat "$CALLS")"
[[ $(stat -c %a "$work/etc/m1n1.conf") == 644 ]] || fail 'm1n1.conf is world-readable, as update-m1n1 reads it'
before=$(conf)
run && [[ $(conf) == "$before" && ! -s $CALLS ]] || fail 'a rerun changes nothing and rebuilds nothing'
machine apple,j615 apple,t8122 apple,arm-platform
rm -rf "$work/etc"
run && has_switches "${switches[@]}" || fail 'the 15-inch M3 Air takes them too' "$(conf)"
pass 'an M3 Air gets the native display and GPU in m1n1.conf and boot.bin, once'

# An Air whose earlier setup wrote only the display line gets the GPU on update.
printf '# omarchy-mac-boot: the M3 Air native display. Set it to 0 to keep m1n1 from handing it over.\nchosen.asahi,t8122-dcp=1\n' >"$work/etc/m1n1.conf"
run && has_switches "${switches[@]}" && [[ $(<"$CALLS") == update-m1n1 ]] ||
  fail 'an Air with only the display line gets the GPU switches, without a second display line' "$(conf)"
# The owner's GPU choices, and the native 25G83 profile's lines, stay theirs.
for owned in chosen.asahi,t8122-gpu=0 chosen.asahi,t8122-gpu=1 chosen.asahi,t8122-gpu-handoff-diag=1 chosen.asahi,j615-25g83-experimental=1; do
  printf 'chosen.asahi,t8122-dcp=1\n%s\n' "$owned" >"$work/etc/m1n1.conf"
  run && [[ $(conf) == $'chosen.asahi,t8122-dcp=1\n'"$owned" && ! -s $CALLS ]] ||
    fail "an owner's $owned keeps the GPU switches out" "$(conf)"
done
printf 'chosen.asahi,t8122-gpu=0\n' >"$work/etc/m1n1.conf"
run && has_switches chosen.asahi,t8122-dcp=1 chosen.asahi,t8122-gpu=0 && ! grep -q 'power-standin' "$work/etc/m1n1.conf" ||
  fail "an owner's GPU off still gets the display, and nothing else" "$(conf)"
for owned in 'chosen.asahi,t8122-dcp=0' 'chosen.asahi,t8122-dcp=' 'chosen.asahi,t8122-dcp= 0' $'chosen.asahi,t8122-dcp=1\nchosen.asahi,t8122-dcp=0'; do
  printf '%s\n' "$owned" >"$work/etc/m1n1.conf"
  run && [[ $(conf) == "$owned" && ! -s $CALLS ]] ||
    fail "the GPU never starts beside a display line that is not exactly 1: '$owned'" "$(conf)"
done
for owned in 'chosen.asahi,t8122-dcp=' $'chosen.asahi,t8122-dcp=1\nchosen.asahi,t8122-dcp='; do
  printf '%s' "$owned" >"$work/etc/m1n1.conf"
  run && [[ $(conf) == "$owned" && ! -s $CALLS ]] ||
    fail "an empty last display line without its newline still keeps the GPU out: '$owned'" "$(conf)"
done
rm -rf "$work/etc"
pass "the GPU switches reach Airs that had only the display, and the owner's GPU choices are kept"

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
CHROOT=1 check_untouched "an arch-chroot that sees the host's /run/systemd/system gets nothing written"
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
grep -Fxq '  m1n1_t8122_dcp_minimum=1.6.1.aurora20-4' "$ROOT/setup/m1n1-display.sh" ||
  fail 'the packaged minimum is the first m1n1-aurora with the dcpext opt-in, pkgrel included'
# The packaged minimum: 20-3 black-screens an M3 Air with the line, 20-4 does not.
machine apple,j613 apple,t8122 apple,arm-platform
PACKAGED=1 VERSION=1.6.1.aurora20-3 check_untouched 'm1n1-aurora 1.6.1.aurora20-3, the black-screen build, gets nothing written'
rm -rf "$work/etc"
PACKAGED=1 VERSION=1.6.1.aurora20-4 run && grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" ||
  fail 'm1n1-aurora 1.6.1.aurora20-4 gets the display line' "$(conf) $(cat "$work/out")"
for newer in 1.6.1.aurora20-10 1.6.1.aurora21-1; do
  rm -rf "$work/etc"
  PACKAGED=1 VERSION=$newer run && grep -Fxq 'chosen.asahi,t8122-dcp=1' "$work/etc/m1n1.conf" ||
    fail "m1n1-aurora $newer, newer than the packaged minimum, gets the display line" "$(conf) $(cat "$work/out")"
done
pass 'only an m1n1-aurora at or above the packaged minimum gets the line on an M3 Air'

# m1n1-aurora 1.6.1.aurora21-1 and later arm the M3 graphics in stage 2 themselves: nothing is
# written, and the =1 block this package wrote earlier goes, while every other line stays.
grep -Fxq '  m1n1_m3_defaults_minimum=1.6.1.aurora21-1' "$ROOT/setup/m1n1-display.sh" ||
  fail 'the packaged defaults minimum is the first m1n1-aurora whose stage 2 arms the M3 graphics'
defaults() { PACKAGED=1 PACKAGED_DEFAULTS=1 VERSION=${1-1.6.1.aurora21-1} run; }
header_v2='# omarchy-mac-boot: the M3 Air native display and GPU. Set a line to 0 to keep m1n1 from handing it over.'
header_v1='# omarchy-mac-boot: the M3 Air native display. Set it to 0 to keep m1n1 from handing it over.'
machine apple,j613 apple,t8122 apple,arm-platform
for version in 1.6.1.aurora21-1 1.6.1.aurora21-2 1.6.1.aurora22-1; do
  rm -rf "$work/etc"
  defaults "$version" && [[ $(conf) == absent && ! -s $CALLS ]] && grep -q 'by default; nothing to write' "$work/out" ||
    fail "m1n1-aurora $version gets nothing written and nothing rebuilt" "$(conf) $(cat "$work/out")"
done
rm -rf "$work/etc"
defaults 1.6.1.aurora20-10 && has_switches "${switches[@]}" ||
  fail 'an m1n1-aurora before the defaults still gets the four switches' "$(conf)"
mkdir -p "$work/etc"
printf 'display=1920x1080\n%s\n%s\nchosen.asahi,other=1\n' "$header_v2" "$(printf '%s\n' "${switches[@]}")" >"$work/etc/m1n1.conf"
defaults && [[ $(conf) == $'display=1920x1080\nchosen.asahi,other=1' && $(<"$CALLS") == update-m1n1 ]] ||
  fail "this package's =1 block goes, the owner's lines stay, and boot.bin is rebuilt once" "$(conf) / $(cat "$CALLS")"
before=$(conf)
defaults && [[ $(conf) == "$before" && ! -s $CALLS ]] || fail 'a rerun changes nothing and rebuilds nothing' "$(conf)"
for machine_name in j613 j615; do
  machine apple,$machine_name apple,t8122 apple,arm-platform
  printf '%s\nchosen.asahi,t8122-dcp=1\n' "$header_v1" >"$work/etc/m1n1.conf"
  defaults && [[ -e $work/etc/m1n1.conf && -z $(conf) && $(<"$CALLS") == update-m1n1 ]] ||
    fail "the first version's display-only block goes too on the $machine_name" "$(conf)"
done
machine apple,j613 apple,t8122 apple,arm-platform
printf '%s\nchosen.asahi,t8122-dcp=1\nchosen.asahi,t8122-gpu=0\nchosen.asahi,t8122-gpu-power-standin=1\n' "$header_v2" >"$work/etc/m1n1.conf"
defaults && [[ $(conf) == $'chosen.asahi,t8122-gpu=0\nchosen.asahi,t8122-gpu-power-standin=1' ]] ||
  fail "an owner's 0 in the block stays, and so does every line after it" "$(conf)"
for owned in 'chosen.asahi,t8122-gpu=1' 'chosen.asahi,t8122-dcp=0' $'display=1920x1080\nchosen.asahi,t8122-dcp=1'; do
  printf '%s\n' "$owned" >"$work/etc/m1n1.conf"
  defaults && [[ $(conf) == "$owned" && ! -s $CALLS ]] ||
    fail "an owner's own line outside this package's block stays as it is: '$owned'" "$(conf)"
done
# Only the two headers exactly as this package wrote them mark its block: an owner's comment that
# starts the same way, or one of those headers with more text, stays byte for byte with its lines.
for header in '# omarchy-mac-boot: the M3 Air native display, my own note' "$header_v2 Mine now." "$header_v1 (kept)" \
  " $header_v1"; do
  printf '%s\n%s\n' "$header" "$(printf '%s\n' "${switches[@]}")" >"$work/etc/m1n1.conf"
  cp "$work/etc/m1n1.conf" "$work/original"
  defaults && cmp -s "$work/etc/m1n1.conf" "$work/original" && [[ ! -s $CALLS ]] ||
    fail "an owner's comment that only starts like this package's header keeps its block: '$header'" "$(conf)"
done
printf '%s\nchosen.asahi,t8122-dcp=1\n%s\nchosen.asahi,t8122-dcp=1\n' "$header_v2" \
  '# omarchy-mac-boot: the M3 Air native display, my own note' >"$work/etc/m1n1.conf"
defaults && [[ $(conf) == $'# omarchy-mac-boot: the M3 Air native display, my own note\nchosen.asahi,t8122-dcp=1' &&
  $(<"$CALLS") == update-m1n1 ]] ||
  fail "only this package's exact block goes; the owner's look-alike comment and its line stay" "$(conf)"
printf '%s\n%s\n' "$header_v2" "$(printf '%s\n' "${switches[@]}")" >"$work/etc/m1n1.conf"
cp "$work/etc/m1n1.conf" "$work/original"
UPDATE_FAILS=1 defaults || fail 'a failed rebuild after the cleanup never fails the setup'
cmp -s "$work/etc/m1n1.conf" "$work/original" && grep -q 'is back as it was' "$work/out" ||
  fail 'a failed rebuild puts the block back byte for byte, and says so' "$(conf)"
for board in 'apple,j516s apple,t6030' 'apple,j514s apple,t6030' 'apple,j504 apple,t8122'; do
  read -r -a compat <<<"$board"
  machine "${compat[@]}" apple,arm-platform
  printf '%s\nchosen.asahi,t8122-dcp=1\n' "$header_v1" >"$work/etc/m1n1.conf"
  cp "$work/etc/m1n1.conf" "$work/original"
  defaults && cmp -s "$work/etc/m1n1.conf" "$work/original" && [[ ! -s $CALLS ]] ||
    fail "another Mac's m1n1.conf is left alone: $board" "$(conf)"
done
rm -rf "$work/etc"
pass "an m1n1-aurora with the M3 defaults gets nothing written, and this package's old switch block goes"

# A failed rebuild leaves m1n1.conf as it was, so the boot check stays consistent.
machine apple,j613 apple,t8122 apple,arm-platform
rm -rf "$work/etc"
UPDATE_FAILS=1 run || fail 'a failed update-m1n1 warns but never fails the setup'
[[ $(conf) == absent ]] && grep -q 'is back as it was' "$work/out" || fail 'a new m1n1.conf is removed again after a failed rebuild, and it says so' "$(conf)"
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
# A full /tmp: one block (1024 bytes in bash's ulimit -f) fits the copy, but not the appends after it.
for ending in '' $'\n'; do
  mkdir -p "$work/etc" && { head -c $((1024 - ${#ending})) /dev/zero | tr '\0' '#'; printf '%s' "$ending"; } >"$work/etc/m1n1.conf"
  cp "$work/etc/m1n1.conf" "$work/original"
  FILE_BLOCKS=1 run || fail 'a staging write that runs out of space never fails the setup'
  cmp -s "$work/etc/m1n1.conf" "$work/original" && [[ ! -s $CALLS ]] && grep -q 'could not stage' "$work/out" && ! grep -q enabled "$work/out" ||
    fail "a staging append that runs out of space leaves m1n1.conf alone and says so (last newline: ${ending:+yes}${ending:-no})" "$(cat "$work/out")"
done
UPDATE_FAILS=1 RESTORE_FAILS=1 run || fail 'a failed restore still never fails the setup'
grep -q 'could not be put back' "$work/out" || fail 'a failed restore says so instead of claiming m1n1.conf is back' "$(cat "$work/out")"
pass 'a failed rebuild puts m1n1.conf back exactly, and the setup carries on'

# 96-omarchy-mac-m3-air.hook runs the leaf again after an update of this package or m1n1-aurora.
hook=$ROOT/files/usr/share/libalpm/hooks/96-omarchy-mac-m3-air.hook
script=$ROOT/files/usr/share/libalpm/scripts/omarchy-mac-m3-air
grep -Fxq 'Type = Package' "$hook" && grep -Fxq 'Target = omarchy-mac-boot' "$hook" && grep -Fxq 'Target = m1n1-aurora' "$hook" &&
  grep -Fxq 'Operation = Upgrade' "$hook" && grep -Fxq 'When = PostTransaction' "$hook" &&
  grep -Fxq "Exec = /${script#"$ROOT/files/"}" "$hook" && [[ -x $script ]] ||
  fail 'the hook runs the packaged script after this package or m1n1-aurora is installed or upgraded'
order=(95-m1n1-install.hook "${hook##*/}")
[[ $(printf '%s\n' "${order[@]}" | LC_ALL=C sort) == "$(printf '%s\n' "${order[@]}")" ]] ||
  fail "the hook runs after 95-m1n1-install.hook, so boot.bin is built last from the switches"
if (( EUID != 0 )); then
  staged=$work/staged
  "$ROOT/install" "$staged"
  [[ -x $staged/usr/share/libalpm/scripts/omarchy-mac-m3-air ]] || fail 'the hook script is installed executable'
  leaf=$staged/usr/lib/omarchy-mac/boot/setup/m1n1-display.sh
  printf 'echo "leaf PATH=$PATH" >>"%s"\nreturn 1\n' "$work/hook-ran" >"$leaf"
  OMARCHY_MAC_BOOT_ROOT=$staged "$staged/usr/share/libalpm/scripts/omarchy-mac-m3-air" ||
    fail 'a failing leaf never fails the pacman transaction'
  grep -q '^leaf ' "$work/hook-ran" || fail 'the hook script runs the staged leaf'
fi
pass 'an update of omarchy-mac-boot or m1n1-aurora runs the M3 Air leaf again, after the m1n1 rebuild, and never fails'
