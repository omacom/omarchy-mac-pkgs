#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage=$tmp/stage
bash "$ROOT/install" "$stage"
helper=$stage/usr/lib/omarchy/mac-boot/snapper-cleanup-sync
[[ -x $helper ]] || fail "the cleanup helper is installed executable"

# Keep the production readiness checks and cleanup helper, with paths pointing
# to a disposable root. The menu writer is the external dependency stub.
sed -e "s|/var/lib/omarchy/limine.enabled|$tmp/limine.enabled|g" \
  -e "s|/etc/default/limine|$tmp/limine.defaults|g" \
  "$stage/usr/lib/omarchy/mac-boot/limine-ready" >"$tmp/limine-ready"
sed -e "s|/usr/lib/omarchy/mac-boot/limine-ready|$tmp/limine-ready|g" \
  -e "s|/usr/bin/limine-snapper-sync|$tmp/sync|g" \
  "$helper" >"$tmp/cleanup-sync"
cat >"$tmp/sync" <<'STUB'
#!/bin/bash
printf 'sync %s\n' "$*" >>"$TEST_CALLS"
exit "${TEST_SYNC_STATUS:-0}"
STUB
chmod +x "$tmp/limine-ready" "$tmp/cleanup-sync" "$tmp/sync"
export TEST_CALLS=$tmp/calls TEST_SYNC_STATUS=0

run_cleanup_sync() {
  status=0
  : >"$TEST_CALLS"
  "$tmp/cleanup-sync" >"$tmp/output" 2>&1 || status=$?
}

run_cleanup_sync
(( status == 0 )) && [[ ! -s $TEST_CALLS ]] || fail "inactive Limine skips only the menu writer successfully"
pass "inactive Limine skips only the menu writer successfully"

touch "$tmp/limine.defaults"
run_cleanup_sync
(( status == 0 )) && [[ ! -s $TEST_CALLS ]] || fail "defaults alone never activate the menu writer"
pass "defaults alone never activate the menu writer"

touch "$tmp/limine.enabled"
run_cleanup_sync
(( status == 0 )) && [[ $(cat "$TEST_CALLS") == 'sync ' ]] || fail "valid activation calls the normal sync without bypass flags"
pass "valid activation calls the normal sync without bypass flags"

for expected in 1 2 100; do
  TEST_SYNC_STATUS=$expected run_cleanup_sync
  (( status == expected )) && [[ -s $TEST_CALLS ]] || fail "an active sync failure stays a failure: $expected"
done
pass "active sync failures including status 100 are not mistaken for inactive readiness"

rm "$tmp/limine.defaults"
run_cleanup_sync
(( status == 1 )) && [[ ! -s $TEST_CALLS ]] || fail "an enabled Mac without defaults fails closed"
pass "an enabled Mac without defaults fails closed"

touch "$tmp/real-defaults"
ln -s "$tmp/real-defaults" "$tmp/limine.defaults"
run_cleanup_sync
(( status == 1 )) && [[ ! -s $TEST_CALLS ]] || fail "symlinked defaults fail closed"
rm "$tmp/limine.defaults" "$tmp/limine.enabled"
touch "$tmp/limine.defaults"
for target in "$tmp/real-defaults" "$tmp/missing"; do
  ln -s "$target" "$tmp/limine.enabled"
  run_cleanup_sync
  (( status == 1 )) && [[ ! -s $TEST_CALLS ]] || fail "a symlinked activation marker fails closed even when dangling"
  rm "$tmp/limine.enabled"
done
mkdir "$tmp/limine.enabled"
run_cleanup_sync
(( status == 1 )) && [[ ! -s $TEST_CALLS ]] || fail "a non-file activation marker fails closed"
pass "invalid defaults and regular, dangling or non-file activation markers fail closed"

rm "$tmp/limine-ready"
run_cleanup_sync
(( status == 127 )) && [[ ! -s $TEST_CALLS ]] || fail "a missing readiness helper is not treated as inactive"
pass "a missing readiness helper is not treated as inactive"

# Reproduce the package-owned upstream unit and its current post-cleanup list.
# No live unit or installed package file is read by this fixture.
units=$stage/usr/lib/systemd/system
mkdir -p "$stage/usr/lib/snapper" "$stage/usr/bin"
cat >"$units/snapper-cleanup.service" <<'UNIT'
[Unit]
Description=Snapper cleanup fixture
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/lib/snapper/systemd-helper --cleanup
UNIT
cat >"$units/snapper-cleanup.service.d/limine-snapper-override.conf" <<'UNIT'
[Service]
ExecStartPre=-touch /run/limine-snapper-cleanup.lock
ExecStopPost=-rm -f /run/limine-snapper-cleanup.lock
ExecStopPost=limine-snapper-sync
UNIT
for command in usr/lib/snapper/systemd-helper usr/bin/rm usr/bin/touch; do
  printf '#!/bin/bash\nexit 0\n' >"$stage/$command"
  chmod +x "$stage/$command"
done
require_command python3
python3 - "$units" <<'PY'
from pathlib import Path
import sys
units = Path(sys.argv[1])
files = [units / 'snapper-cleanup.service', *sorted((units / 'snapper-cleanup.service.d').glob('*.conf'))]
commands = {'ExecStart': [], 'ExecStartPre': [], 'ExecStopPost': []}
for path in files:
    section = ''
    for line in path.read_text().splitlines():
        if line.startswith('['):
            section = line
        if section != '[Service]' or '=' not in line:
            continue
        key, value = line.split('=', 1)
        if key in commands:
            if not value:
                commands[key].clear()
            else:
                commands[key].append(value)
assert commands['ExecStart'] == ['/usr/lib/snapper/systemd-helper --cleanup'], commands
assert commands['ExecStartPre'] == ['-touch /run/limine-snapper-cleanup.lock'], commands
assert commands['ExecStopPost'] == [
    '-/usr/bin/rm -f /run/limine-snapper-cleanup.lock',
    '/usr/lib/omarchy/mac-boot/snapper-cleanup-sync',
], commands
PY
pass "the merged unit keeps Snapper cleanup and both cleanup-lock operations"
require_command systemd-analyze
systemd-analyze verify --root="$stage" snapper-cleanup.service >"$tmp/verify.log" 2>&1 || {
  cat "$tmp/verify.log" >&2
  fail "systemd accepts the staged cleanup unit and drop-ins"
}
pass "systemd accepts the staged cleanup unit and drop-ins"
