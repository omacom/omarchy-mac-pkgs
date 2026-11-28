#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
command -v pacman-conf >/dev/null || fail 'pacman-conf is required'
command -v vercmp >/dev/null || fail 'vercmp is required'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
helper="$ROOT/bin/omarchy-mac-drop-asahi-alarm"
key=12CE6799A94A3F1B5DDFFE88F576553597FB8FEB
arm_key=68B3537F39A313B3E574D06777193F152BDBE6A6

# pacman and pacman-key act on files in the case's directory: installed and
# synced ("name version" lines, synced being [omarchy]), old-repo (names in
# [asahi-alarm]), elsewhere (names other remaining repositories carry),
# required-by (the keyring's dependents) and keys.
stubs="$test_tmp/bin"
mkdir -p "$stubs"
stub_apple_predicate "$stubs"
cat >"$stubs/omarchy-hw-platform" <<'EOF'
#!/bin/bash
echo "$TEST_PLATFORM"
EOF
cat >"$stubs/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >>"$TEST_CASE/log"
installed() { grep "^$1 " "$TEST_CASE/installed"; }
case $1 in
  -Q) installed "$3" ;;
  -Qq) cut -d' ' -f1 "$TEST_CASE/installed" ;;
  -Qi)
    installed "$3" >/dev/null || exit 1
    echo "Name            : $3"
    echo "Required By     : $(cat "$TEST_CASE/required-by")"
    ;;
  -Slq) cat "$TEST_CASE/old-repo" ;;
  -Si)
    if [[ $2 == omarchy/* ]]; then
      line=$(grep "^${2#omarchy/} " "$TEST_CASE/synced") || exit 1
      echo "Repository      : omarchy"
      echo "Version         : ${line#* }"
    else
      grep -q "^$3 " "$TEST_CASE/synced" || grep -qx "$3" "$TEST_CASE/elsewhere"
    fi
    ;;
  -R)
    [[ ${TEST_REMOVE_FAILS:-0} == 0 ]] || { echo "error: failed to init transaction (unable to lock database)" >&2; exit 1; }
    grep -v "^$4 " "$TEST_CASE/installed" >"$TEST_CASE/installed.new" || true
    mv "$TEST_CASE/installed.new" "$TEST_CASE/installed"
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$stubs/pacman-key" <<'EOF'
#!/bin/bash
echo "pacman-key $*" >>"$TEST_CASE/log"
case $1 in
  --list-keys) grep -qx "$2" "$TEST_CASE/keys" ;;
  --delete) grep -vx "$2" "$TEST_CASE/keys" >"$TEST_CASE/keys.new" || true; mv "$TEST_CASE/keys.new" "$TEST_CASE/keys" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stubs"/*

# A live pacman.conf with [asahi-alarm] between Omarchy's repository and Arch
# Linux ARM's, a header with trailing whitespace, and an administrator's own
# options and repository around it.
write_conf() {
  cat >"$1" <<EOF
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
IgnorePkg = example

[omarchy]
Server = https://pkgs.omarchy.org/edge/\$arch

[asahi-alarm]
Server = https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64

[core]
Include = $2/mirrorlist

[extra]
Include = $2/mirrorlist

[alarm]
Include = $2/mirrorlist

[custom]
Server = https://example.com/\$arch
EOF
}

# What a Mac looks like after the update that brought this package: the
# aurora-* replacements and higher-pkgrel builds are in, and only asahi-alarm's
# steam sorts above [omarchy]'s.
new_case() {
  local case_dir="$test_tmp/$1"
  mkdir -p "$case_dir/etc" "$case_dir/share"
  write_conf "$case_dir/etc/pacman.conf" "$case_dir"
  chmod 640 "$case_dir/etc/pacman.conf"
  echo 'Server = https://arm-mirror.omarchy.org/$arch/$repo' >"$case_dir/mirrorlist"
  printf '%s\n' 'aurora-scripts 20261023-1' 'lzfse 1.0-2' 'speakersafetyd 2.0.1-2' 'bankstown 1.1.0-3' \
    'widevine 4.10.2891.0-2' 'fex-emu 2604-1' 'asahi-alarm-keyring 20241216-1' 'omarchy-mac 0.2.7-1' \
    'steam 20241231-4' 'fex-emu-rootfs-arch 20260318-1' >"$case_dir/installed"
  printf '%s\n' asahi-scripts asahi-fwextract lzfse speakersafetyd bankstown triforce-lv2 widevine muvm FEX-Emu \
    asahi-alarm-keyring steam fex-emu-rootfs-arch >"$case_dir/old-repo"
  printf '%s\n' 'aurora-scripts 20261023-1' 'aurora-fwextract 0.9.2-1' 'lzfse 1.0-2' 'speakersafetyd 2.0.1-2' \
    'bankstown 1.1.0-3' 'triforce-lv2 0.3.2-2' 'widevine 4.10.2891.0-2' 'muvm 0.7.0-2' 'fex-emu 2604-1' \
    'omarchy-mac 0.2.7-1' 'steam 1.0.0.87-2' >"$case_dir/synced"
  : >"$case_dir/elsewhere"
  echo None >"$case_dir/required-by"
  printf '%s\n' "$key" "$arm_key" >"$case_dir/keys"
  printf '# Signing keyrings\n' >"$case_dir/share/keyrings"
  : >"$case_dir/log"
  echo "$case_dir"
}

run_helper() {
  local case_dir=$1
  env -i \
    PATH="$stubs:/usr/bin:/bin" \
    TEST_CASE="$case_dir" \
    TEST_PLATFORM="${TEST_PLATFORM:-aarch64-apple}" \
    TEST_REMOVE_FAILS="${TEST_REMOVE_FAILS:-0}" \
    OMARCHY_MAC_ASAHI_ALARM_STATE="$case_dir/state" \
    OMARCHY_MAC_PACMAN_CONF="${TEST_CONF:-$case_dir/etc/pacman.conf}" \
    OMARCHY_MAC_PLATFORM_KEYRINGS="$case_dir/share/keyrings" \
    OMARCHY_MAC_PACMAN_LOCK="$case_dir/db.lck" \
    OMARCHY_MAC_PACMAN_LOCK_WAIT=1 \
    bash "$helper"
}

repos() { pacman-conf --config "$1" --repo-list | tr '\n' ' '; }
changed_nothing() {
  local case_dir=$1 original=$2
  [[ $(cat "$case_dir/etc/pacman.conf") == "$original" && ! -e $case_dir/etc/pacman.conf.bak-asahi-alarm ]] &&
    grep -q '^asahi-alarm-keyring ' "$case_dir/installed" && grep -qx "$key" "$case_dir/keys" &&
    ! grep -q '^pacman -R\|^pacman-key --delete' "$case_dir/log" && [[ ! -e $case_dir/state/done ]]
}

# ── the move ─────────────────────────────────────────────────────────────────

case_dir=$(new_case move)
original=$(cat "$case_dir/etc/pacman.conf")
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'the helper moves a Mac off [asahi-alarm]' "$(cat "$case_dir/out")"
[[ $(repos "$case_dir/etc/pacman.conf") == "omarchy core extra alarm custom " ]] ||
  fail 'only [asahi-alarm] leaves pacman.conf' "$(repos "$case_dir/etc/pacman.conf")"
grep -qx 'IgnorePkg = example' "$case_dir/etc/pacman.conf" || fail "the administrator's options stay"
! grep -q 'asahi-alarm' "$case_dir/etc/pacman.conf" || fail 'nothing of the section stays' "$(cat "$case_dir/etc/pacman.conf")"
[[ $(cat "$case_dir/etc/pacman.conf.bak-asahi-alarm") == "$original" ]] || fail 'the old pacman.conf is kept as a backup'
[[ $(stat -c %a "$case_dir/etc/pacman.conf") == 640 ]] || fail 'pacman.conf keeps its mode' "$(stat -c %a "$case_dir/etc/pacman.conf")"
grep -qx 'pacman -R --noconfirm -- asahi-alarm-keyring' "$case_dir/log" || fail 'the keyring package is removed' "$(cat "$case_dir/log")"
! grep -qx "$key" "$case_dir/keys" && grep -qx "$arm_key" "$case_dir/keys" || fail "only the asahi-alarm key leaves pacman's keyring"
! grep -Eq '^pacman -(S|Su|Sy|Syu|U) ' "$case_dir/log" || fail 'the helper installs and upgrades nothing' "$(cat "$case_dir/log")"
[[ -e $case_dir/state/done ]] || fail 'the machine is marked done'
grep -qx 'steam 20241231-4: newer than omarchy.s 1.0.0.87-2, so pacman keeps it; switch with: pacman -S omarchy/steam' "$case_dir/out" ||
  fail "it names asahi-alarm's steam and the switch to Omarchy's" "$(cat "$case_dir/out")"
grep -qx 'fex-emu-rootfs-arch 20260318-1: no repository carries it any more, so it gets no updates' "$case_dir/out" ||
  fail 'it names what no repository carries any more' "$(cat "$case_dir/out")"
! grep -q '^lzfse\|^widevine\|^asahi-alarm-keyring' "$case_dir/state/report" || fail 'the imports Omarchy took over are not reported'
pass 'the helper drops [asahi-alarm], its keyring and its key, keeps everything else, and reports what Omarchy does not take over'

# ── idempotency ──────────────────────────────────────────────────────────────

moved=$(cat "$case_dir/etc/pacman.conf")
: >"$case_dir/log"
run_helper "$case_dir" >/dev/null 2>&1 || fail 'the helper runs again'
[[ ! -s $case_dir/log && $(cat "$case_dir/etc/pacman.conf") == "$moved" ]] || fail 'a marked machine is left alone' "$(cat "$case_dir/log")"
rm "$case_dir/state/done"
run_helper "$case_dir" >/dev/null 2>&1 || fail 'the helper runs on a moved machine without its marker'
[[ $(cat "$case_dir/etc/pacman.conf") == "$moved" && -e $case_dir/state/done ]] || fail 'a moved machine is verified and marked again'
! grep -q '^pacman -R\|^pacman-key --delete' "$case_dir/log" || fail 'a moved machine only looks' "$(cat "$case_dir/log")"
pass 'the helper is idempotent, with or without its marker'

# ── the repository comes back ────────────────────────────────────────────────

# An older Omarchy's template written over the moved pacman.conf, as a channel
# switch or omarchy-refresh-pacman does.
write_conf "$case_dir/etc/pacman.conf" "$case_dir"
: >"$case_dir/log"
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'the helper runs on a marked machine whose [asahi-alarm] came back' "$(cat "$case_dir/out")"
grep -q '^\[asahi-alarm\] is back in ' "$case_dir/out" || fail 'it says the repository came back' "$(cat "$case_dir/out")"
[[ $(repos "$case_dir/etc/pacman.conf") == "omarchy core extra alarm custom " && -e $case_dir/state/done ]] ||
  fail 'the returned repository is dropped again and the machine marked again' "$(repos "$case_dir/etc/pacman.conf")"
! grep -Eq '^pacman -(R|S|Su|Sy|Syu|U) ' "$case_dir/log" || fail 'only pacman.conf changes' "$(cat "$case_dir/log")"

write_conf "$case_dir/etc/pacman.conf" "$case_dir"
echo 'asahi-alarm-keyring 20241216-1' >>"$case_dir/installed"
echo 'omarchy-mac-boot' >"$case_dir/required-by"
returned=$(cat "$case_dir/etc/pacman.conf")
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'a returned repository that is still needed is not a failure' "$(cat "$case_dir/out")"
grep -q 'omarchy-mac-boot still requires asahi-alarm-keyring' "$case_dir/out" && [[ $(cat "$case_dir/etc/pacman.conf") == "$returned" && ! -e $case_dir/state/done ]] ||
  fail 'the guards still hold, and the machine is pending again' "$(cat "$case_dir/out")"
pass 'a repository that comes back after the move is dropped again, behind the same guards'

# ── no-ops ───────────────────────────────────────────────────────────────────

for platform in x86 aarch64 aarch64-qualcomm; do
  case_dir=$(new_case "other-$platform")
  TEST_PLATFORM=$platform run_helper "$case_dir" >/dev/null 2>&1 || fail "the helper completes on $platform"
  [[ ! -s $case_dir/log && ! -e $case_dir/state ]] || fail "the helper does nothing on $platform" "$(cat "$case_dir/log")"
done
pass 'the helper does nothing on anything but an Apple Silicon Mac'

case_dir=$(new_case fresh)
sed -i '/^\[asahi-alarm\]/,/^$/d' "$case_dir/etc/pacman.conf"
sed -i '/^asahi-alarm-keyring /d' "$case_dir/installed"
sed -i "/^$key\$/d" "$case_dir/keys"
fresh=$(cat "$case_dir/etc/pacman.conf")
run_helper "$case_dir" >/dev/null 2>&1 || fail 'the helper completes on a Mac without [asahi-alarm]'
[[ $(cat "$case_dir/etc/pacman.conf") == "$fresh" && ! -e $case_dir/etc/pacman.conf.bak-asahi-alarm && -e $case_dir/state/done ]] ||
  fail 'a Mac that never had [asahi-alarm] is marked done, untouched'
! grep -q '^pacman -R\|^pacman-key --delete' "$case_dir/log" || fail 'it is only looked at' "$(cat "$case_dir/log")"
pass 'a Mac without [asahi-alarm], its keyring or its key is marked done untouched'

case_dir=$(new_case stray-key)
sed -i '/^\[asahi-alarm\]/,/^$/d' "$case_dir/etc/pacman.conf"
sed -i '/^asahi-alarm-keyring /d' "$case_dir/installed"
run_helper "$case_dir" >/dev/null 2>&1 || fail 'the helper completes with only the key left'
! grep -qx "$key" "$case_dir/keys" && [[ -e $case_dir/state/done ]] || fail 'the key goes even when the repository and package are gone'
pass "the asahi-alarm key is deleted by fingerprint when nothing else of it is left"

# ── staying pending ──────────────────────────────────────────────────────────

case_dir=$(new_case unpublished)
sed -i 's/^aurora-scripts .*/asahi-scripts 20261023-1/' "$case_dir/installed"
sed -i '/^aurora-scripts /d' "$case_dir/synced"
original=$(cat "$case_dir/etc/pacman.conf")
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'a pending move is not a failure' "$(cat "$case_dir/out")"
grep -q 'omarchy/aurora-scripts is not in this channel' "$case_dir/out" || fail 'it says which build is missing' "$(cat "$case_dir/out")"
changed_nothing "$case_dir" "$original" || fail 'nothing changes while the channel lacks a build' "$(cat "$case_dir/log")"
[[ -s $case_dir/state/inventory ]] || fail "what came from [asahi-alarm] is recorded on the first run"
pass 'the helper stays pending, changing nothing, while the channel lacks an Omarchy build'

case_dir=$(new_case not-installed)
sed -i '/^fex-emu /d' "$case_dir/synced"
sed -i '/^fex-emu /d' "$case_dir/installed"
run_helper "$case_dir" >/dev/null 2>&1 && [[ -e $case_dir/state/done ]] || fail 'the helper needs only the installed imports'
pass 'the helper checks only the imports that are installed'

for holder in required listed; do
  case_dir=$(new_case "still-$holder")
  if [[ $holder == required ]]; then
    echo 'omarchy-mac-boot' >"$case_dir/required-by"
    expected='omarchy-mac-boot still requires asahi-alarm-keyring'
  else
    echo asahi-alarm-keyring >>"$case_dir/share/keyrings"
    expected='still lists asahi-alarm-keyring'
  fi
  original=$(cat "$case_dir/etc/pacman.conf")
  run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail "a keyring still $holder is not a failure" "$(cat "$case_dir/out")"
  grep -q "$expected" "$case_dir/out" || fail "it says why the keyring is still needed ($holder)" "$(cat "$case_dir/out")"
  changed_nothing "$case_dir" "$original" || fail "the repository stays while the keyring is $holder" "$(cat "$case_dir/log")"
done
pass 'the repository stays, with its keyring and key, while a package requires the keyring or the platform root lists it'

case_dir=$(new_case busy)
: >"$case_dir/db.lck"
original=$(cat "$case_dir/etc/pacman.conf")
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'a busy pacman is not a failure'
grep -q 'pacman is still busy' "$case_dir/out" && changed_nothing "$case_dir" "$original" && [[ ! -s $case_dir/log ]] ||
  fail 'nothing runs while pacman holds its database' "$(cat "$case_dir/log")"
pass 'the helper waits for pacman to release its database, and stays pending if it does not'

case_dir=$(new_case remove-fails)
TEST_REMOVE_FAILS=1 run_helper "$case_dir" >/dev/null 2>&1 || fail 'a keyring removal that fails is not a failure'
[[ $(repos "$case_dir/etc/pacman.conf") == "omarchy core extra alarm custom " ]] || fail 'the repository is already gone'
grep -q '^asahi-alarm-keyring ' "$case_dir/installed" && grep -qx "$key" "$case_dir/keys" && [[ ! -e $case_dir/state/done ]] ||
  fail 'the keyring and its key stay, unmarked'
run_helper "$case_dir" >"$case_dir/out" 2>&1 || fail 'the rerun finishes'
! grep -q '^asahi-alarm-keyring ' "$case_dir/installed" && ! grep -qx "$key" "$case_dir/keys" && [[ -e $case_dir/state/done ]] ||
  fail 'the rerun removes the keyring and its key'
grep -q '^steam 20241231-4: newer than' "$case_dir/out" || fail "the rerun still reports from the first run's record" "$(cat "$case_dir/out")"
pass 'a keyring removal that fails stays pending, and the rerun finishes from the recorded inventory'

# ── a symlinked pacman.conf ──────────────────────────────────────────────────

case_dir=$(new_case symlink)
mv "$case_dir/etc/pacman.conf" "$case_dir/etc/pacman.conf.real"
ln -s pacman.conf.real "$case_dir/etc/pacman.conf"
run_helper "$case_dir" >/dev/null 2>&1 || fail 'the helper moves a symlinked pacman.conf'
[[ -L $case_dir/etc/pacman.conf && $(readlink "$case_dir/etc/pacman.conf") == pacman.conf.real ]] || fail 'the symlink stays'
[[ $(repos "$case_dir/etc/pacman.conf") == "omarchy core extra alarm custom " && $(stat -c %a "$case_dir/etc/pacman.conf.real") == 640 ]] ||
  fail 'its target is rewritten in place, keeping its mode'
[[ -e $case_dir/etc/pacman.conf.real.bak-asahi-alarm ]] || fail 'the backup sits beside the target'
pass "a symlinked pacman.conf keeps its link; the target is rewritten with its mode"

# ── how it is queued ─────────────────────────────────────────────────────────

unit="$ROOT/vendor/systemd/system/omarchy-mac-drop-asahi-alarm.service"
hook="$ROOT/share/libalpm/hooks/91-omarchy-mac-drop-asahi-alarm.hook"
! grep -q '^ConditionPathExists' "$unit" &&
  grep -q 'state=${OMARCHY_MAC_ASAHI_ALARM_STATE:-/var/lib/omarchy/mac-drop-asahi-alarm}' "$helper" ||
  fail "the unit leaves the marker to the helper, which rechecks pacman.conf"
[[ $(readlink "$ROOT/vendor/systemd/system/multi-user.target.wants/omarchy-mac-drop-asahi-alarm.service") == ../omarchy-mac-drop-asahi-alarm.service ]] ||
  fail 'every boot retries'
grep -qx 'Target = \*' "$hook" && grep -q 'systemctl --quiet --no-block start omarchy-mac-drop-asahi-alarm.service' "$hook" ||
  fail 'every transaction queues it without waiting'
grep -qF '[ -e /var/lib/omarchy/mac-drop-asahi-alarm/done ] && ! pacman-conf --repo-list 2>/dev/null | grep -qx asahi-alarm;' "$hook" ||
  fail 'a marked machine is queued again only while [asahi-alarm] is back'
! grep -q 'pacman ' <(grep '^Exec' "$hook") || fail 'the hook never runs pacman itself'
pass 'boot and every pacman transaction queue the helper until it is done or while [asahi-alarm] is back, without running pacman inside pacman'
