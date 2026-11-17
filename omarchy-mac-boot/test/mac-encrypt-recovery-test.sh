#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$ROOT/files/usr/lib/omarchy/initcpio/omarchy-mac-encrypt
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/boot/omarchy"
cat >"$tmp/bin/cryptsetup" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >>"$CASE/calls"
case $1 in
  open) [[ ! -e $CASE/wrong-key ]] ;;
  luksHeaderBackup)
    shift
    [[ $1 == --header-backup-file ]] || exit 1
    [[ ! -e $2 ]] || exit 5
    printf 'original-header' >"$2"
    [[ ! -e $CASE/backup-fails ]] || exit 6
    ;;
  repair) [[ ! -e $CASE/repair-fails ]] ;;
  luksDump) cat "$CASE/metadata" ;;
  reencrypt)
    [[ ! -e $CASE/reencrypt-fails ]] || exit 7
    printf 'resumed\n'
    ;;
  luksUUID) printf '00000000-0000-0000-0000-000000000001\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/cryptsetup"
printf '%064d' 0 >"$tmp/boot/omarchy/luks-key"
run() {
  CASE=$tmp PATH="$tmp/bin:$PATH" BOOT_MNT=$tmp/boot ROOT_DEV=/dev/test-root \
    OMARCHY_MAC_ENCRYPT_PROGRESS_FILE=$tmp/progress OMARCHY_MAC_ENCRYPT_FAILED_FILE=$tmp/failed \
    bash -euo pipefail -c '
      source "$1"
      if [[ -e $CASE/stale-temp ]]; then
        printf partial >"$BOOT_MNT/omarchy/luks-header-before-repair.tmp.$$"
      fi
      omarchy_mac_encrypt_reencrypt resume
    ' bash "$SCRIPT" >"$tmp/out" 2>&1
}
reset_case() {
  rm -f "$tmp/calls" "$tmp/wrong-key" "$tmp/repair-fails" "$tmp/reencrypt-fails" "$tmp/failed" "$tmp/boot/omarchy/luks-header-before-repair"
  rm -f "$tmp/stale-temp" "$tmp/backup-fails" "$tmp"/boot/omarchy/luks-header-before-repair.tmp.*
}
printf '%s\n' '{"keyslots":{"1":{"type":"reencrypt"}},"segments":{}}' >"$tmp/metadata"
run || fail "pending conversion repairs before resuming"
[[ $(cat "$tmp/calls") == $'open\nluksHeaderBackup\nrepair\nluksDump\nreencrypt\nluksUUID' ]] || fail "key authentication, backup, repair and resume order"
[[ $(stat -c %a "$tmp/boot/omarchy/luks-header-before-repair") == 600 ]] || fail "header backup is private"
[[ $(cat "$tmp/boot/omarchy/luks-header-before-repair") == original-header ]] || fail "header backup retained before durable finish"
[[ $(stat -c %a "$tmp/boot/omarchy/encrypt.log") == 600 ]] || fail "persistent diagnostics must be private"
grep -q 'LUKS2 resume exited status=0' "$tmp/boot/omarchy/encrypt.log" || fail "successful command status is recorded"
: >"$tmp/calls"
run || fail "repeated resume preserves the original header evidence"
! grep -qx luksHeaderBackup "$tmp/calls" || fail "existing header evidence must not be overwritten"
reset_case
: >"$tmp/stale-temp"
run || fail "a reused staging path must not block recovery"
[[ $(cat "$tmp/boot/omarchy/luks-header-before-repair") == original-header ]] || fail "stale staging data is replaced by the full backup"
reset_case
: >"$tmp/backup-fails"
if run; then fail "a partial header backup must stop recovery"; fi
! grep -qx repair "$tmp/calls" || fail "repair must not run after a partial backup"
[[ ! -e $tmp/boot/omarchy/luks-header-before-repair ]] || fail "partial backup is never published"
compgen -G "$tmp/boot/omarchy/luks-header-before-repair.tmp.*" >/dev/null || fail "partial backup retained until cleanup"
rm "$tmp/backup-fails"
run || fail "recovery retries after an interrupted backup"
BOOT_MNT=$tmp/boot bash -euo pipefail -c 'source "$1"; omarchy_mac_encrypt_remove_recovery_backup' bash "$SCRIPT"
! compgen -G "$tmp/boot/omarchy/luks-header-before-repair*" >/dev/null || fail "completion removes all temporary backups"
reset_case
printf '%s\n' '{"keyslots":{"0":{"type":"luks2"}},"segments":{"0":{"type":"crypt"}}}' >"$tmp/metadata"
run || fail "completed conversion with stale journal finishes"
! grep -qx reencrypt "$tmp/calls" || fail "already-completed conversion must not call --resume-only"
grep -q 'conversion already complete' "$tmp/out" || fail "completed conversion is reported"
reset_case
: >"$tmp/wrong-key"
if run; then fail "wrong saved key must refuse recovery"; fi
[[ $(cat "$tmp/calls") == open ]] || fail "no backup, repair or conversion after failed authentication"
reset_case
: >"$tmp/repair-fails"
if run; then fail "failed crash recovery must fail closed"; fi
[[ -f $tmp/boot/omarchy/luks-header-before-repair ]] || fail "failed recovery retains pre-repair metadata"
! grep -qx reencrypt "$tmp/calls" || fail "repair failure must not resume"
reset_case
printf '%s\n' '{"keyslots":{},"config":{"requirements":{"mandatory":["online-reencrypt-v2"]}},"segments":{}}' >"$tmp/metadata"
if run; then fail "unresolved reencryption requirement must not count as completed"; fi
! grep -qx reencrypt "$tmp/calls" || fail "inconsistent metadata is not resumed"
reset_case
printf '%s\n' '{"keyslots":{"1":{"type":"reencrypt"}},"segments":{}}' >"$tmp/metadata"
: >"$tmp/reencrypt-fails"
if run; then fail "a failed cryptsetup command must fail the conversion"; fi
grep -q 'LUKS2 resume exited status=7' "$tmp/boot/omarchy/encrypt.log" || fail "actual cryptsetup failure status must be retained"
reset_case
mv "$tmp/boot/omarchy/encrypt.log" "$tmp/diagnostics.saved"
ln -s /dev/full "$tmp/boot/omarchy/encrypt.log"
run || fail "unavailable diagnostic storage must not stop conversion"
[[ -L $tmp/boot/omarchy/encrypt.log ]] || fail "logger must not replace an existing symlink"
printf untouched >"$tmp/unrelated"
ln -s "$tmp/unrelated" "$tmp/boot/omarchy/luks-header-before-repair.tmp.symlink"
printf obsolete >"$tmp/boot/omarchy/luks-header-before-repair.tmp.other-pid"
BOOT_MNT=$tmp/boot bash -euo pipefail -c 'source "$1"; omarchy_mac_encrypt_remove_recovery_backup' bash "$SCRIPT"
[[ ! -e $tmp/boot/omarchy/luks-header-before-repair ]] || fail "durable completion removes obsolete header evidence"
! compgen -G "$tmp/boot/omarchy/luks-header-before-repair*" >/dev/null || fail "all header staging copies are removed"
[[ $(cat "$tmp/unrelated") == untouched ]] || fail "cleanup must not follow a staging symlink"
CASE=$tmp BOOT_MNT=$tmp/boot ROOT_DEV=/dev/test-root \
  OMARCHY_MAC_ENCRYPT_FAILED_FILE=$tmp/failed bash -euo pipefail -c '
  source "$1"
  STATE_PHASE=reencrypting
  omarchy_mac_encrypt_inconsistent "manual recovery test"
' bash "$SCRIPT" >"$tmp/hint" 2>&1 && fail "inconsistent state must stop"
grep -q 'Verify key: cryptsetup open --test-passphrase' "$tmp/hint" || fail "repair hint authenticates first"
grep -q 'Repair: cryptsetup repair' "$tmp/hint" || fail "repair hint includes recovery"
grep -q 'Then resume: cryptsetup reencrypt --resume-only' "$tmp/hint" || fail "repair hint resumes only after repair"
grep -q '\.tmp.\* staging copies' "$tmp/hint" || fail "repair hint identifies temporary backup evidence"
echo 'ok - interrupted LUKS2 recovery authenticates, preserves metadata, repairs, and distinguishes completed conversion'
