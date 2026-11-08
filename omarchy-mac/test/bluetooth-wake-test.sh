#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
rule="$stage/usr/lib/udev/rules.d/95-omarchy-mac-bluetooth-wake.rules"
hook="$stage/usr/share/libalpm/hooks/95-omarchy-mac-bluetooth-wake.hook"
[[ -f $rule && -f $hook ]] || fail 'stages the udev rule and the pacman hook'
while read -r key _ target; do
  [[ $key == "Target" && -e $stage/$target ]] || fail 'hook targets a staged file' "$target"
done < <(grep '^Target' "$hook")
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --resolve-names=never "$rule" >/dev/null || fail 'udev rule verifies'
fi
pass 'stages a udev rule and a pacman hook for Bluetooth wake'

# A fixture /sys: an Apple root port with Wi-Fi and Bluetooth below it, and a
# T2 Mac's BCM4377 under another port.
sys="$work/sys"
pci="$sys/devices/platform/soc/pcie/pci0000:00"
device() {
  mkdir -p "$pci/$1/$2/power"
  printf '%s\n' "$3" >"$pci/$1/$2/vendor"
  printf '%s\n' "$4" >"$pci/$1/$2/device"
  printf 'disabled\n' >"$pci/$1/$2/power/wakeup"
  ln -s "../../../devices/platform/soc/pcie/pci0000:00/$1/$2" "$sys/bus/pci/devices/$2"
}
mkdir -p "$sys/bus/pci/devices" "$pci/0000:00:00.0/power" "$pci/0000:00:01.0/power" "$sys/class/power_supply/macsmc-ac"
device 0000:00:00.0 0000:01:00.0 0x14e4 0x4433
device 0000:00:00.0 0000:01:00.1 0x14e4 0x5f71
device 0000:00:01.0 0000:02:00.1 0x14e4 0x5fa0
printf 'disabled\n' >"$pci/0000:00:00.0/power/wakeup"
printf 'disabled\n' >"$pci/0000:00:01.0/power/wakeup"

mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-1} == "1" ]]
STUB
chmod +x "$work/bin/omarchy-hw-apple-silicon"
sync="$work/bluetooth-wake-sync"
sed "s|^sys=/sys$|sys=$sys|" "$stage/usr/lib/omarchy-mac/bluetooth-wake-sync" >"$sync"
chmod +x "$sync"
run() { PATH="$work/bin:$PATH" APPLE="${APPLE:-1}" "$sync" || fail 'never fails'; }
state() { cat "$pci/0000:00:00.0/power/wakeup" "$pci/0000:00:00.0/0000:01:00.1/power/wakeup" | paste -sd' '; }
untouched() {
  [[ $(cat "$pci/0000:00:00.0/0000:01:00.0/power/wakeup") == "disabled" && $(cat "$pci/0000:00:01.0/power/wakeup") == "disabled" &&
    $(cat "$pci/0000:00:01.0/0000:02:00.1/power/wakeup") == "disabled" ]] || fail "$1 leaves Wi-Fi and a T2 BCM4377 alone"
}

printf '1\n' >"$sys/class/power_supply/macsmc-ac/online"
run
[[ $(state) == "enabled enabled" ]] || fail 'charger connected enables the port and the Bluetooth function' "$(state)"
untouched 'enabling'
pass 'charger connected: Bluetooth input can wake the Mac'

printf '0\n' >"$sys/class/power_supply/macsmc-ac/online"
run
[[ $(state) == "disabled disabled" ]] || fail 'on battery disables both' "$(state)"
pass 'on battery: Bluetooth input cannot wake the Mac'

printf 'enabled\n' | tee "$pci/0000:00:00.0/power/wakeup" "$pci/0000:00:00.0/0000:01:00.1/power/wakeup" >/dev/null
rm "$sys/class/power_supply/macsmc-ac/online"
run
[[ $(state) == "disabled disabled" ]] || fail 'an unreadable charger counts as on battery' "$(state)"
pass 'without a charger reading: wake stays off'

printf '1\n' >"$sys/class/power_supply/macsmc-ac/online"
APPLE=0 run
[[ $(state) == "disabled disabled" ]] || fail 'off Apple Silicon changes nothing' "$(state)"
untouched 'off Apple Silicon'
pass 'off Apple Silicon: changes nothing'
