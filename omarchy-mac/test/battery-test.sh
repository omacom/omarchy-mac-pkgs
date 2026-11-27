#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
rule="$stage/usr/lib/udev/rules.d/94-omarchy-mac-battery-charge-limit.rules"
[[ -x $stage/usr/bin/omarchy-battery-charge-limit && -x $stage/usr/lib/omarchy-mac/battery-charge-limit-restore && -f $rule ]] || fail 'stages the command, restore helper and udev rule'
grep -Fxq 'ACTION=="add", SUBSYSTEM=="power_supply", KERNEL=="macsmc-battery", RUN+="/usr/lib/omarchy-mac/battery-charge-limit-restore"' "$rule" || fail 'rule runs the staged helper only for the SMC battery'
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --resolve-names=never "$rule" >/dev/null || fail 'udev rule verifies'
fi
pass 'stages a udev rule that restores the limit for the SMC battery only'

# asahi-scripts' unit as it ships, which its path unit starts on every SMC event.
unit=macsmc-battery-charge-control-end-threshold.service
stub_systemd_boot_targets "$stage"
printf '#!/bin/sh\nexit 0\n' >"$stage/usr/bin/sh"
chmod +x "$stage/usr/bin/sh"
cat >"$stage/usr/lib/systemd/system/$unit" <<'UNIT'
[Unit]
Description=Store current charge_control_end_threshold value persistently

[Service]
Type=simple
ExecStart=sh -c 'echo "CHARGE_CONTROL_END_THRESHOLD=$(cat /sys/class/power_supply/macsmc-battery/charge_control_end_threshold)" > /etc/udev/macsmc-battery.conf'
UNIT
# systemd reads the setting only from [Unit].
limit=$(systemd-analyze --root="$stage" cat-config "systemd/system/$unit" |
  awk -F= '/^\[/ { section = $0 } section == "[Unit]" && $1 == "StartLimitIntervalSec" { value = $2 } END { print value }')
[[ $limit == "0" ]] || fail 'a burst of SMC events never hits the start limit' "(StartLimitIntervalSec=${limit:-unset})"
pass "lifts the start limit on asahi-scripts' charge-threshold unit"

# verify warns about a setting systemd ignores but still exits 0, so any output
# fails, unless a trivial unit fails too, as in emulated containers.
printf '[Service]\nExecStart=sh -c true\n' >"$stage/usr/lib/systemd/system/probe.service"
if verify=$(systemd-analyze --root="$stage" verify --man=no "/usr/lib/systemd/system/$unit" 2>&1) && [[ -z $verify ]]; then
  pass 'systemd accepts the drop-in without warnings'
elif probe=$(systemd-analyze --root="$stage" verify --man=no /usr/lib/systemd/system/probe.service 2>&1) && [[ -z $probe ]]; then
  fail 'systemd accepts the drop-in without warnings' "$verify"
else
  pass 'systemd-analyze cannot verify units here; drop-in verification not run'
fi

battery="$work/sys/macsmc-battery"
saved="$work/etc/udev/macsmc-battery.conf"
mkdir -p "$battery" "${saved%/*}" "$work/bin"
export BATTERY="$battery" SAVED="$saved" SUDO_LOG="$work/sudo.log"

# Point the commands at a fixture battery and saved-limit file, and mark the
# charge-limit command's root branch so the root case below can turn it on.
fixture() {
  sed -e "s|/sys/class/power_supply/macsmc-battery|$battery|" \
    -e "s|/etc/udev/macsmc-battery.conf|$saved|" \
    -e 's/(( EUID == 0 ))/(( 1 == 0 ))/' "$1" >"$2"
  chmod +x "$2"
}
command="$work/bin/omarchy-battery-charge-limit"
restore="$work/battery-charge-limit-restore"
fixture "$stage/usr/bin/omarchy-battery-charge-limit" "$command"
fixture "$stage/usr/lib/omarchy-mac/battery-charge-limit-restore" "$restore"

cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
if [[ ${PLATFORM:-aarch64-apple} == "contradiction" ]]; then
  echo "Error: contradictory platform identity" >&2
  exit 1
fi
echo "${PLATFORM:-aarch64-apple}"
STUB
stub_apple_predicate "$work/bin"
# The SMC derives the start threshold from the end threshold.
cat >"$work/bin/sudo" <<'STUB'
#!/bin/bash
(( $# == 2 )) && [[ $1 == "/usr/bin/tee" ]] || exit 1
printf '%s\n' "$2" >>"$SUDO_LOG"
value=$(cat)
if [[ $2 == $BATTERY/charge_control_end_threshold ]]; then
  [[ ${SUDO_FAIL:-} != 1 ]] || exit 1
  [[ ${SUDO_IGNORE:-} != 1 ]] || exit 0
  printf '%s\n' "$value" >"$2"
  if [[ $value == "80" ]]; then
    printf '75\n' >"$BATTERY/charge_control_start_threshold"
  else
    printf '100\n' >"$BATTERY/charge_control_start_threshold"
  fi
elif [[ $2 == $SAVED ]]; then
  [[ ${SAVE_FAIL:-} != 1 ]] || exit 1
  printf '%s\n' "$value" >"$2"
else
  exit 1
fi
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

smc() {
  printf '%s\n' "$1" >"$battery/charge_control_start_threshold"
  printf '%s\n' "$2" >"$battery/charge_control_end_threshold"
}
reads() {
  [[ $(<"$battery/charge_control_start_threshold") == $1 && $(<"$battery/charge_control_end_threshold") == $2 ]]
}
smc 100 100

[[ $("$command") == "Charge limit: 100% (restart charging at 100%)" ]] || fail 'reports the active limit'
[[ ! -e $SUDO_LOG && ! -e $saved ]] || fail 'status needs no privilege and saves nothing'
pass 'reports the active Apple Silicon charge thresholds'

[[ $("$command" 80) == "Charge limit set to 80% (restart charging at 75%)." ]] || fail 'reports the 80% cap'
reads 75 80 || fail 'sets the 80% cap and five point hysteresis'
[[ $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=80" ]] || fail 'saves the 80% cap for the next boot'
"$command" 100 >/dev/null
reads 100 100 || fail 'restores full charging'
[[ $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=100" ]] || fail 'saves full charging for the next boot'
(( $(grep -c charge_control_end_threshold "$SUDO_LOG") == 2 && $(grep -c -v charge_control_end_threshold "$SUDO_LOG") == 2 )) || fail 'writes only the end threshold and the saved limit once per change'
pass 'sets and clears the limit and saves it for the next boot'

if SUDO_FAIL=1 "$command" 80 >/dev/null 2>&1; then fail 'reports a failed threshold update'; fi
reads 100 100 && [[ $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=100" ]] || fail 'a failed write changes nothing'
if SUDO_IGNORE=1 "$command" 80 >/dev/null 2>&1; then fail 'reports an update that did not stick'; fi
[[ $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=100" ]] || fail 'an update that did not stick is not saved'
if SAVE_FAIL=1 "$command" 80 >/dev/null 2>"$work/err"; then fail 'reports a limit that could not be saved'; fi
grep -Fq 'could not be saved' "$work/err" || fail 'says the limit was not saved'
"$command" 100 >/dev/null
pass 'checks the driver readback and reports failed writes and saves'

# As root the command writes both files itself, without sudo.
sed 's/(( 1 == 0 ))/(( 0 == 0 ))/' "$command" >"$work/root-command"
chmod +x "$work/root-command"
: >"$SUDO_LOG"
smc 75 100
"$work/root-command" 80 >/dev/null || fail 'root sets the limit'
reads 75 80 && [[ $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=80" && ! -s $SUDO_LOG ]] || fail 'root writes the threshold and saved limit without sudo'
"$command" 100 >/dev/null
pass 'root sets and saves the limit without sudo'

: >"$SUDO_LOG"
for args in 85 0 '80 100'; do
  # shellcheck disable=SC2086
  if "$command" $args >/dev/null 2>&1; then fail "rejects $args"; fi
done
reads 100 100 && [[ ! -s $SUDO_LOG ]] || fail 'invalid input leaves the limit unchanged'
pass 'rejects unsupported limits without changing the device'

for platform in qualcomm aarch64 x86 contradiction; do
  for args in '' 80 100; do
    # shellcheck disable=SC2086
    if PLATFORM=$platform "$command" $args >/dev/null 2>&1; then fail "$platform refuses ${args:-status}"; fi
  done
done
reads 100 100 && [[ ! -s $SUDO_LOG && $(<"$saved") == "CHARGE_CONTROL_END_THRESHOLD=100" ]] || fail 'non-Apple platforms leave the battery and saved limit alone'
rm "$battery/charge_control_start_threshold"
if "$command" >/dev/null 2>"$work/err"; then fail 'reports missing thresholds'; fi
grep -Fq 'not available' "$work/err" || fail 'explains missing thresholds'
smc 100 100
pass 'refuses on non-Apple platforms and on kernels without thresholds'

# A reboot resets the fixture SMC to full charging; the udev helper reapplies
# the saved limit.
"$command" 80 >/dev/null
smc 100 100
"$restore" || fail 'restore succeeds'
[[ $(<"$battery/charge_control_end_threshold") == 80 ]] || fail 'restores the saved 80% cap after a reboot'
"$command" 100 >/dev/null
printf 'sentinel\n' >"$battery/charge_control_end_threshold"
"$restore"
[[ $(<"$battery/charge_control_end_threshold") == 100 ]] || fail 'restores saved full charging'
printf 'CHARGE_CONTROL_END_THRESHOLD=100\nCHARGE_CONTROL_END_THRESHOLD=80' >"$saved"
"$restore"
[[ $(<"$battery/charge_control_end_threshold") == 80 ]] || fail 'the last saved value wins, with or without a final newline'
pass 'reapplies the saved limit, including one saved by asahi-scripts'

untouched() {
  printf 'sentinel\n' >"$battery/charge_control_end_threshold"
  "$@" || fail 'restore never fails the udev event'
  [[ $(<"$battery/charge_control_end_threshold") == "sentinel" ]]
}
rm "$saved"
untouched "$restore" || fail 'no saved limit leaves the SMC alone'
for content in 'CHARGE_CONTROL_END_THRESHOLD=85' 'CHARGE_CONTROL_END_THRESHOLD=60' 'CHARGE_CONTROL_END_THRESHOLD="80"' 'CHARGE_CONTROL_END_THRESHOLD=80 ' 'OTHER=80' ''; do
  printf '%s\n' "$content" >"$saved"
  untouched "$restore" || fail "ignores saved content: $content"
done
printf 'CHARGE_CONTROL_END_THRESHOLD=80\n' >"$saved"
for platform in qualcomm aarch64 x86 contradiction; do
  PLATFORM=$platform untouched "$restore" || fail "$platform leaves the battery alone"
done
rm "$battery/charge_control_end_threshold"
"$restore" || fail 'restore without a battery succeeds'
[[ ! -e $battery/charge_control_end_threshold ]] || fail 'restore without a battery writes nothing'
pass 'restore ignores unsupported saved values, missing batteries and non-Apple platforms'
