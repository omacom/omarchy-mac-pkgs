#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
[[ -x $stage/usr/bin/omarchy-power-report ]] || fail 'stages the power report'

# A fake M1 Pro: sysfs, /proc, a sleep log and powerprofilesctl.
sys="$work/sys" proc="$work/proc"
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >"$1"; }
supply="$sys/class/power_supply"
put "$supply/macsmc-battery/type" Battery
put "$supply/macsmc-battery/present" 1
put "$supply/macsmc-battery/status" Discharging
put "$supply/macsmc-battery/energy_now" 45000000
put "$supply/macsmc-battery/energy_full" 60000000
put "$supply/macsmc-battery/power_now" -6250000
put "$supply/macsmc-ac/type" Mains
put "$supply/macsmc-ac/online" 0
put "$supply/tps6598x-source-psy-0-0038/type" USB
put "$supply/tps6598x-source-psy-0-0038/online" 0
printf 'Apple MacBook Pro (14-inch, M1 Pro, 2021)\0' >"$work/model"
mkdir -p "$sys/firmware/devicetree/base" && mv "$work/model" "$sys/firmware/devicetree/base/model"
cpu="$sys/devices/system/cpu"
for policy in 0:"0 1":2064000:600000 2:"2 3 4 5":3036000:1296000; do
  IFS=: read -r number cpus max now <<<"$policy"
  put "$cpu/cpufreq/policy$number/related_cpus" "$cpus"
  put "$cpu/cpufreq/policy$number/scaling_driver" apple-cpufreq
  put "$cpu/cpufreq/policy$number/scaling_governor" schedutil
  put "$cpu/cpufreq/policy$number/cpuinfo_min_freq" 600000
  put "$cpu/cpufreq/policy$number/cpuinfo_max_freq" "$max"
  put "$cpu/cpufreq/policy$number/scaling_min_freq" 600000
  put "$cpu/cpufreq/policy$number/scaling_max_freq" "$max"
  put "$cpu/cpufreq/policy$number/scaling_cur_freq" "$now"
done
put "$cpu/cpufreq/policy2/scaling_max_freq" 2000000
for number in 0 1 2 3 4 5; do mkdir -p "$cpu/cpu$number"; done
put "$cpu/cpuidle/current_driver" apple_idle
put "$cpu/cpuidle/current_governor_ro" menu
put "$cpu/cpu0/cpuidle/state0/name" WFI
put "$cpu/cpu0/cpuidle/state0/desc" 'CPU clock-gated'
put "$cpu/cpu0/cpuidle/state0/disable" 0
put "$cpu/cpu0/cpuidle/state1/name" 'CPU PD'
put "$cpu/cpu0/cpuidle/state1/desc" 'CPU/cluster powered down'
put "$cpu/cpu0/cpuidle/state1/disable" 1
mkdir -p "$sys/bus/platform/drivers/apple_pmp"
put "$sys/power/mem_sleep" '[s2idle]'
put "$proc/sys/kernel/osrelease" 7.1.12-2-12-ARCH
put "$proc/stat" 'cpu  100 0 100 800 0 0 0 0 0 0'
put "$proc/1/stat" '1 (systemd) S 0 1 1 0 -1 4194560 0 0 0 0 10 10 0 0 20 0 1 0 1 0 0'
put "$proc/42/stat" '42 (Web Content) S 1 42 42 0 -1 4194560 0 0 0 0 100 50 0 0 20 0 1 0 1 0 0'
put "$proc/77/stat" '77 (hypr land) S 1 77 77 0 -1 4194560 0 0 0 0 5 5 0 0 20 0 1 0 1 0 0'
mkdir -p "$work/bin" "$work/state"
cat >"$work/bin/powerprofilesctl" <<'STUB'
#!/bin/bash
printf '  performance:\n    PlatformDriver:\tplaceholder\n\n* balanced:\n    PlatformDriver:\tplaceholder\n\n  power-saver:\n    PlatformDriver:\tplaceholder\n'
STUB
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/powerprofilesctl" "$work/bin/omarchy-hw-apple-silicon"
printf 'start_boot_id=b action=suspend start_real=1791500000.000 start_boot=100.000 start_energy=50000000 start_status=Discharging start_charger=0 boot_id=b end_real=1791528800.000 end_boot=28900.000 end_energy=34000000 end_status=Discharging end_charger=0 energy_full=60000000 verdict=valid\n' >"$work/state/sleep-cost.log"
export OMARCHY_SYS_ROOT="$sys" OMARCHY_PROC_ROOT="$proc" OMARCHY_MAC_SLEEP_LOG="$work/state/sleep-cost.log" TZ=UTC PATH="$work/bin:$PATH"

report=$("$stage/usr/bin/omarchy-power-report" --sample 0.1 2>/dev/null)
expect() { grep -Fq -- "$1" <<<"$report" || fail "$2" "$(printf '\n%s' "$report")"; }
expect 'Mac: Apple MacBook Pro (14-inch, M1 Pro, 2021)' 'names the Mac'
expect 'Kernel: 7.1.12-2-12-ARCH' 'names the kernel'
expect 'Power profile: balanced (no platform driver, so profiles change nothing on this Mac)' 'says the power profiles do nothing'
expect 'macsmc-battery: Discharging, 45.0 of 60.0 Wh (75%)' 'reports the charge'
expect 'Battery draw now: 6.25 W' 'reports the draw, unsigned'
expect 'macsmc-ac (Mains power): not connected' 'reports the adapter'
expect 'tps6598x-source-psy-0-0038 (USB power): not connected' 'reports each USB-C power source'
expect 'policy0 (CPUs 0 1): apple-cpufreq, schedutil, hardware 600-2064 MHz, allowed 600-2064 MHz, now 600 MHz' 'reports a policy'
expect 'policy2 (CPUs 2 3 4 5): apple-cpufreq, schedutil, hardware 600-3036 MHz, allowed 600-2000 MHz, now 1296 MHz' 'reports a lowered limit'
expect 'Driver apple_idle, governor menu' 'reports the cpuidle driver'
expect 'state1: CPU PD, CPU/cluster powered down (disabled)' 'reports a disabled idle state'
expect 'PMP: apple_pmp is present but bound to no device' 'reports an unbound PMP'
expect 'Sleep states: [s2idle]' 'reports mem_sleep'
expect 'Last suspend: 2026-10-08 22:53 to 2026-10-09 06:53: used 16.0 Wh over 8.0 h (2.00 W average), 27% of a full battery.' 'reports the last sleep'
expect 'CPU activity over 0.1 s (share of one core; a measure of activity, not of power):' 'labels the sample as activity'
pass 'the report covers the battery, power sources, CPU limits, idle states, PMP and the last sleep'

ln -s ../../../devices/platform/soc/28e3c0000.pmp "$sys/bus/platform/drivers/apple_pmp/28e3c0000.pmp"
put "$supply/macsmc-battery/status" Full
put "$supply/macsmc-battery/power_now" 0
put "$supply/macsmc-ac/online" 1
rm "$work/state/sleep-cost.log"
report=$("$stage/usr/bin/omarchy-power-report" --sample 0.1 2>/dev/null)
expect 'PMP: apple_pmp bound to 28e3c0000.pmp.' 'reports a bound PMP'
expect 'Battery draw now: 0.00 W; a charger powering the Mac hides its draw, so unplug it to measure.' 'says the charger hides the draw'
expect 'macsmc-ac (Mains power): connected' 'reports a connected adapter'
expect 'Last suspend: No suspend recorded yet.' 'reports no sleep yet'
pass 'the report says when the charger hides the draw and when PMP is bound'

python3 - "$stage/usr/bin/omarchy-power-report" "$proc" <<'PY'
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('report', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
r = importlib.util.module_from_spec(spec); loader.exec_module(r)
proc = Path(sys.argv[2])
ticks = os.sysconf('SC_CLK_TCK')


def busy(seconds):
    # Over the sample, Web Content uses half a core, hypr land a tenth, systemd
    # nothing, and a process that starts during it is left out.
    def stat(pid, name, total):
        (proc / pid / 'stat').write_text('%s (%s) S 1 1 1 0 -1 0 0 0 0 0 %d 0 0 0 20 0 1 0 1 0 0\n' % (pid, name, total))
    stat('42', 'Web Content', 150 + int(0.5 * ticks * seconds))
    stat('77', 'hypr land', 10 + int(0.1 * ticks * seconds))
    (proc / '99').mkdir()
    stat('99', 'newcomer', 500)
    (proc / 'stat').write_text('cpu  %d 0 100 %d 0 0 0 0 0 0\n' % (100 + int(0.6 * ticks * seconds), 800 + int(5.4 * ticks * seconds)))


lines = r.activity_section(10, sleep=busy)
expected = ['CPU activity over 10 s (share of one core; a measure of activity, not of power):',
            '  All 6 cores: 10% busy', '   50.0%  42      Web Content', '   10.0%  77      hypr land']
if lines != expected:
    print('not ok - the sample ranks processes by CPU share\n%s' % '\n'.join(lines), file=sys.stderr)
    raise SystemExit(1)
if any(re.search(r'\d\s*W\b|watt', line, re.IGNORECASE) for line in lines):
    print('not ok - CPU activity is never given as power', file=sys.stderr)
    raise SystemExit(1)
PY
pass 'the CPU sample ranks processes by their share of one core, never as watts'
