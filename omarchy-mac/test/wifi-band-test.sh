#!/bin/bash

# NetworkManager's iwd never starts a 6 GHz join, where the BCM4388 firmware
# passes no traffic, except on the N1, which keeps iwd's own defaults; an
# administrator's iwd configuration still decides instead of the package.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
"$ROOT"/install "$root"

mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo "${PLATFORM:-aarch64-apple}"
STUB
chmod +x "$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo "Network controller [0280]: [${WIFI_ID:-14e4:4434}]"
STUB
chmod +x "$work/bin/lspci"
export PATH="$work/bin:$PATH"

# Arch's iwd unit, which gives iwd /etc/iwd as its configuration directory.
mkdir -p "$root/usr/lib/systemd/system"
printf '[Service]\nExecStart=/usr/lib/iwd/iwd\nConfigurationDirectory=iwd\n' >"$root/usr/lib/systemd/system/iwd.service"

unit_setting() {
  systemd-analyze --root="$root" cat-config systemd/system/iwd.service | sed -n "s/^$1=//p" | tail -n 1
}

# The main.conf iwd loads: the unit's last CONFIGURATION_DIRECTORY assignment
# after systemd merges its drop-ins, split on colons, first main.conf found.
# An absolute link resolves inside the staged root.
iwd_config() {
  local list dirs dir config
  list=$(unit_setting Environment | sed -n 's/^CONFIGURATION_DIRECTORY=//p')
  IFS=: read -ra dirs <<<"${list:-/etc/iwd}"
  for dir in "${dirs[@]}"; do
    config="$root$dir/main.conf"
    if [[ -L $config ]]; then
      config="$root$(readlink "$config")"
    fi
    if [[ -f $config ]]; then
      echo "$config"
      return 0
    fi
  done
  return 1
}

# A band iwd scans and joins on: its [Rank] modifier is unset or nonzero.
band_enabled() {
  local config=$1 key=$2 value
  value=$(awk -F= -v key="$key" '/^\[/ { section = $0 } section == "[Rank]" && $1 == key { print $2 }' "$config")
  [[ -z $value ]] || awk -v v="$value" 'BEGIN { exit !(v + 0 != 0) }'
}

# What iwd's start runs first, as systemd runs it, against the staged root.
iwd_start() {
  local command
  command=$(unit_setting ExecStartPre)
  [[ $command == "-+/usr/lib/omarchy-mac/iwd-config" ]] || fail "iwd's start prepares its configuration" "$command"
  "$root/usr/lib/omarchy-mac/iwd-config" "$root"
}

# The BCM4388, BCM4387, BCM4378, a MediaTek chip, a T2 Mac with the N1's ID,
# and a failing lspci: the Apple default, 2.4 and 5 GHz but never 6 GHz.
apple_default() {
  config=$(iwd_config) || fail "iwd finds a configuration ($1)"
  [[ $config == "$root/usr/lib/omarchy-mac/iwd/main.conf" ]] || fail "iwd loads the Apple default ($1)" "$config"
  ! band_enabled "$config" BandModifier6GHz || fail "iwd never joins 6 GHz ($1)"
  # iwd refuses to start unless 2.4 GHz and 5 GHz stay enabled.
  band_enabled "$config" BandModifier2_4GHz && band_enabled "$config" BandModifier5GHz ||
    fail "iwd still joins 2.4 GHz and 5 GHz ($1)"
}
apple_default "fresh install, before iwd starts"
for spec in 'aarch64-apple 14e4:4434' 'aarch64-apple 14e4:4433' 'aarch64-apple 14e4:4425' \
  'aarch64-apple 14c3:7932' 'x86 106b:1900'; do
  read -r platform wifi <<<"$spec"
  PLATFORM=$platform WIFI_ID=$wifi iwd_start
  apple_default "$spec"
done
mkdir -p "$work/failing"
printf '#!/bin/bash\nexit 1\n' >"$work/failing/lspci"
chmod +x "$work/failing/lspci"
WIFI_ID=106b:1900 PATH="$work/failing:$PATH" iwd_start
apple_default "lspci fails"
pass "iwd joins 2.4 GHz and 5 GHz but never 6 GHz on every Mac but the N1"

# The N1's two functions; the next start on another chip undoes it.
for wifi in 106b:1900 106b:1901; do
  WIFI_ID=$wifi iwd_start
  config=$(iwd_config) || fail "iwd finds a configuration on the N1 ($wifi)"
  [[ $config == "$root/usr/lib/omarchy-mac/iwd-centauri/main.conf" ]] || fail "iwd loads the N1 default ($wifi)" "$config"
  band_enabled "$config" BandModifier6GHz || fail "iwd joins 6 GHz on the N1 ($wifi)"
  WIFI_ID=14e4:4434 iwd_start
  apple_default "after the N1 ($wifi)"
done
pass "iwd keeps its own defaults, 6 GHz included, on the N1 only"

mkdir -p "$root/etc/iwd"
printf '[General]\nAddressRandomization=network\n' >"$root/etc/iwd/main.conf"
config=$(iwd_config)
[[ $config == "$root/etc/iwd/main.conf" ]] || fail "an administrator main.conf replaces the Apple default" "$config"
band_enabled "$config" BandModifier6GHz || fail "the administrator decides about 6 GHz"
pass "an administrator's /etc/iwd/main.conf replaces the Apple default"

rm "$root/etc/iwd/main.conf"
mkdir -p "$root/etc/systemd/system/iwd.service.d"
printf '[Service]\n' >"$root/etc/systemd/system/iwd.service.d/20-omarchy-mac.conf"
config=$(iwd_config) && fail "a same-name /etc drop-in removes the Apple default" "$config"
[[ -z $(unit_setting ExecStartPre) ]] || fail "a same-name /etc drop-in removes the Apple start step"
pass "a same-name /etc drop-in removes the Apple default"
