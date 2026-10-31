#!/bin/bash

# NetworkManager, not iwd, autoconnects the MT7932: iwd gives up after the
# firmware rejects a connect. Other Wi-Fi chips keep iwd's autoconnect.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
"$ROOT"/install "$root"
conf="$root/usr/lib/NetworkManager/conf.d/20-omarchy-mac-wifi.conf"
[[ -f $conf ]] || fail 'the NetworkManager Wi-Fi default is installed'

# The value a key takes for a device with the given driver: the first
# [device-*] section whose match-device names the driver, else [device].
device_value() {
  awk -F= -v driver="$1" -v key="$2" '
    /^\[/ { section = $0; matched = section == "[device]" ? "default" : ""; next }
    section ~ /^\[device-/ && $1 == "match-device" && $2 == "driver:" driver { matched = "driver" }
    $1 == key && matched == "driver" && specific == "" { specific = $2 }
    $1 == key && section == "[device]" { fallback = $2 }
    END { print (specific != "" ? specific : fallback) }
  ' "$conf"
}

[[ $(device_value mt7932-fullmac wifi.backend) == "iwd" ]] || fail 'the MT7932 keeps the iwd backend'
[[ $(device_value mt7932-fullmac wifi.iwd.autoconnect) == "false" ]] || fail 'NetworkManager autoconnects the MT7932'
pass 'NetworkManager autoconnects the MT7932'

for driver in brcmfmac brcmfmac_wcc; do
  [[ -z $(device_value "$driver" wifi.iwd.autoconnect) ]] || fail "$driver keeps iwd's autoconnect"
done
pass "Broadcom Wi-Fi keeps iwd's autoconnect"
