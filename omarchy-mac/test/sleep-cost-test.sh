#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
hook="$stage/usr/lib/systemd/system-sleep/omarchy-mac-sleep-cost"
unit="$stage/usr/lib/systemd/user/omarchy-sleep-cost.service"
[[ -x $hook && -x $stage/usr/lib/omarchy-mac/sleep-cost ]] || fail 'stages an executable sleep hook and its helper'
grep -Fxq 'exec /usr/lib/omarchy-mac/sleep-cost "$@"' "$hook" || fail 'the hook runs the helper, which checks the platform'
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/sleep-cost watch' "$unit" && grep -Fxq 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$unit" ||
  fail 'the user unit watches for resumes on Apple Silicon only'
[[ $(readlink "$stage/usr/lib/systemd/user/graphical-session.target.wants/omarchy-sleep-cost.service") == ../omarchy-sleep-cost.service ]] ||
  fail 'the user unit is enabled for every user'
pass 'stages the sleep hook, its helper and the enabled user unit'

python3 - "$stage/usr/lib/omarchy-mac/sleep-cost" "$work" <<'PY'
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import time

helper, work = sys.argv[1], Path(sys.argv[2])
supplies = work / 'sys/class/power_supply'
os.environ.update(OMARCHY_POWER_SUPPLY_PATH=str(supplies), OMARCHY_MAC_SLEEP_LOG=str(work / 'state/sleep-cost.log'),
                  OMARCHY_MAC_SLEEP_PENDING=str(work / 'run/sleep-cost.pending'), OMARCHY_PROC_ROOT=str(work / 'proc'))
os.environ['TZ'] = 'UTC'
time.tzset()
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('sleep_cost', helper)
spec = importlib.util.spec_from_loader(loader.name, loader)
s = importlib.util.module_from_spec(spec); loader.exec_module(s)


def fail(message, detail=''):
    print('not ok - %s %s' % (message, detail), file=sys.stderr)
    raise SystemExit(1)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value + '\n')


def battery(energy, status='Discharging', ac='0', usb='0'):
    write(supplies / 'macsmc-battery/type', 'Battery')
    write(supplies / 'macsmc-battery/present', '1')
    write(supplies / 'macsmc-battery/status', status)
    write(supplies / 'macsmc-battery/energy_full', '60000000')
    if energy is None:
        (supplies / 'macsmc-battery/energy_now').unlink(missing_ok=True)
    else:
        write(supplies / 'macsmc-battery/energy_now', str(energy))
    write(supplies / 'macsmc-ac/type', 'Mains')
    write(supplies / 'macsmc-ac/online', ac)
    write(supplies / 'tps6598x-source-psy-0-0038/type', 'USB')
    write(supplies / 'tps6598x-source-psy-0-0038/online', usb)


class Fake(s.System):
    def __init__(self):
        self.real, self.boot, self.boot_identity = 1791500000.0, 1000.0, 'boot-a'
        self.locks = []; self.notices = []; self.waited = 0.0
    def clocks(self): return self.real, self.boot
    def boot_id(self): return self.boot_identity
    def sleep(self, seconds): self.waited += seconds
    def locked(self): return self.locks.pop(0) if self.locks else False
    def notify(self, headline, body): self.notices.append((headline, body))


def suspend(fake, hours, before, after, real_hours=None, **states):
    battery(before, **states.get('start', {}))
    fake.real += 60; fake.boot += 60
    s.main(['pre', 'suspend'], fake)
    fake.boot += hours * 3600
    fake.real += (hours if real_hours is None else real_hours) * 3600
    battery(after, **states.get('end', {}))
    s.main(['post', 'suspend'], fake)
    return s.last_record()


fake = Fake()
if s.describe(s.last_record()) != 'No suspend recorded yet.':
    fail('reports that no suspend is recorded yet')

record = suspend(fake, 8, 50000000, 34000000)
if record['verdict'] != 'valid' or s.notice(record, fake) != 'Suspend used 16.0 Wh over 8.0 h.':
    fail('a discharging sleep counts', str(record))
if s.describe(record) != '2026-10-08 22:54 to 2026-10-09 06:54: used 16.0 Wh over 8.0 h (2.00 W average), 27% of a full battery.':
    fail('the report line gives the energy, time and average draw: ' + s.describe(record))
if (work / 'run/sleep-cost.pending').exists() or os.stat(s.LOG).st_mode & 0o777 != 0o644:
    fail('the pending reading is consumed and the log is readable by every user')
print('ok - a sleep on battery records its energy over the suspend-inclusive boot clock')

cases = [
    ('charging', dict(start=dict(status='Charging')), 50000000, 51000000),
    ('charger-connected', dict(end=dict(ac='1', status='Not charging')), 50000000, 49900000),
    ('charger-connected', dict(start=dict(usb='1')), 50000000, 49000000),
    ('energy-rose', {}, 50000000, 50100000),
    ('missing-reading', {}, 50000000, None),
    ('missing-reading', {}, None, 49000000),
]
for verdict, states, before, after in cases:
    record = suspend(fake, 8, before, after, **states)
    if record['verdict'] != verdict or s.notice(record, fake) is not None:
        fail('%s is rejected and not announced: %s' % (verdict, record))
    if 'not counted, because' not in s.describe(record):
        fail('the report says why %s was not counted' % verdict)
print('ok - charging, a connected charger, a gain and missing readings are rejected')

record = suspend(fake, 0.03, 50000000, 49000000, real_hours=8)
if record['verdict'] != 'clocks-disagree':
    fail('a boot clock that missed the sleep is rejected', str(record))
record = suspend(fake, 8, 50000000, 49000000, real_hours=8.2)
if record['verdict'] != 'clocks-disagree':
    fail('a wall clock step during the sleep is rejected', str(record))
record = suspend(fake, 8, 50000000, 49000000, real_hours=8.01)
if record['verdict'] != 'valid':
    fail('clocks agreeing within the tolerance count', str(record))
print('ok - the wall clock and the boot clock must agree on the sleep')

battery(50000000)
s.PENDING.unlink(missing_ok=True)
s.main(['post', 'suspend'], fake)
if s.last_record()['verdict'] != 'missing-reading':
    fail('a resume without a pre-sleep reading is rejected')
battery(50000000)
s.main(['pre', 'suspend'], fake)
fake.boot_identity = 'boot-b'; fake.boot = 30.0
s.main(['post', 'suspend'], fake)
if s.last_record()['verdict'] != 'missing-reading':
    fail('a pre-sleep reading from another boot is rejected')
print('ok - a resume without its own pre-sleep reading is rejected')

record = suspend(fake, 0.25, 50000000, 49500000)
if record['verdict'] != 'valid' or s.notice(record, fake) is not None:
    fail('a short sleep is recorded but not announced')
record = suspend(fake, 8, 50000000, 34000000)
fake.boot += s.RECENT + 1
if s.notice(record, fake) is not None:
    fail('a record older than this resume is not announced')
fake.boot_identity = 'boot-c'
if s.notice(record, fake) is not None:
    fail('a record from another boot is not announced')
print('ok - short sleeps and stale records are not announced')

fake = Fake(); fake.boot_identity = 'boot-d'
record = suspend(fake, 8, 50000000, 34000000)
fake.locks = [True, True, True]
shown = set()
s.after_resume(fake, shown)
if fake.notices != [('Suspend used 16.0 Wh over 8.0 h.', 'Overnight suspend can substantially drain this Mac.')] or fake.locks:
    fail('the notice waits for the unlock: %s' % fake.notices)
s.after_resume(fake, shown)
if len(fake.notices) != 1:
    fail('a record is announced once')


class Sleeps(Fake):
    def locked(self):
        if self.locks:
            self.locks.pop(0)
            suspend(self, 1, 30000000, 29000000)
            return True
        return False


fake = Sleeps(); fake.boot_identity = 'boot-e'
suspend(fake, 8, 50000000, 34000000)
fake.locks = [True]
s.after_resume(fake, set())
if fake.notices:
    fail('a sleep superseded while locked is left to its own resume')
print('ok - the notice appears once, after the unlock, for the newest sleep only')

fake = Fake()
for _ in range(s.KEEP + 5):
    suspend(fake, 0.1, 50000000, 49900000)
if len(s.LOG.read_text().splitlines()) != s.KEEP:
    fail('the log keeps the newest %d sleeps' % s.KEEP)
print('ok - the log stays small')
PY
pass 'sleep cost records, rejections and notices'
