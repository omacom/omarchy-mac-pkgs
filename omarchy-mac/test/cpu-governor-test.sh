#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
rule="$stage/usr/lib/udev/rules.d/95-omarchy-mac-cpu-governor.rules"
[[ -x $stage/usr/lib/omarchy-mac/cpu-governor-policy && -f $rule ]] || fail 'stages the helper and the udev rule'
grep -Fxq 'ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="macsmc-ac", RUN+="/usr/lib/omarchy-mac/cpu-governor-policy"' "$rule" || fail 'rule runs the staged helper only for the SMC AC supply'
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --resolve-names=never "$rule" >/dev/null || fail 'udev rule verifies'
fi
pass 'stages a udev rule that sets the CPU governor for the SMC AC supply only'

sys="$work/sys"
mkdir -p "$sys/ac" "$sys/cpufreq/policy0" "$sys/cpufreq/policy4" "$sys/cpufreq/policy8" "$work/bin"
helper="$work/cpu-governor-policy"
sed -e "s|/sys/class/power_supply/macsmc-ac/online|$sys/ac/online|" \
  -e "s|/sys/devices/system/cpu/cpufreq/policy\*|$sys/cpufreq/policy*|" \
  "$stage/usr/lib/omarchy-mac/cpu-governor-policy" >"$helper"
chmod +x "$helper"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
chmod +x "$work/bin/"*

reset() {
  for policy in "$sys"/cpufreq/policy*; do
    printf 'schedutil\n' >"$policy/scaling_governor"
    printf 'conservative ondemand userspace powersave performance schedutil\n' >"$policy/scaling_available_governors"
  done
}
run() { PATH="$work/bin:$PATH" "$helper"; }
governors() { cat "$sys"/cpufreq/policy*/scaling_governor | sort -u | tr '\n' ' '; }

reset
echo 1 >"$sys/ac/online"
run
[[ $(governors) == "performance " ]] || fail 'AC online sets performance on every policy'
pass 'AC online sets performance on every policy'

echo 0 >"$sys/ac/online"
run
[[ $(governors) == "schedutil " ]] || fail 'AC offline returns every policy to schedutil'
pass 'AC offline returns every policy to schedutil'

reset
echo 2 >"$sys/ac/online"
run
[[ $(governors) == "schedutil " ]] || fail 'an unknown AC value leaves the governors alone'
rm "$sys/ac/online"
run
[[ $(governors) == "schedutil " ]] || fail 'a missing AC supply leaves the governors alone'
pass 'an unknown or missing AC state leaves the governors alone'

reset
echo 1 >"$sys/ac/online"
printf 'conservative ondemand schedutil\n' >"$sys/cpufreq/policy4/scaling_available_governors"
run
[[ $(<"$sys/cpufreq/policy0/scaling_governor") == performance && $(<"$sys/cpufreq/policy4/scaling_governor") == schedutil ]] ||
  fail 'a policy without the governor keeps its own'
pass 'a policy that lacks the governor keeps its own'

reset
echo 1 >"$sys/ac/online"
PLATFORM=x86_64 run
[[ $(governors) == "schedutil " ]] || fail 'a machine that is not an Apple Silicon Mac is left alone'
pass 'a machine that is not an Apple Silicon Mac is left alone'
