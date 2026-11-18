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

# NetworkManager's per-key lookup for a device on the given driver, over the
# plain subset this file uses: [device-*] sections with one driver: match, in
# file order, then [device]. Anything outside that subset fails the model.
device_value() {
  awk -F= -v driver="$1" -v key="$2" '
    /^\[/ { name[++n] = $0; next }
    /^[[:space:]]*(#|$)/ { next }
    { value[n, $1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        if (name[i] == "[device]") { fallback = value[i, key]; continue }
        if (name[i] !~ /^\[device-/) continue
        match_device = value[i, "match-device"]
        if (match_device !~ /^driver:[^,;]+$/ || value[i, "stop-match"] != "") { print "UNSUPPORTED"; exit }
        if (match_device == "driver:" driver && (i, key) in value) { print value[i, key]; exit }
      }
      print fallback
    }
  ' "$3"
}

[[ $(device_value mt7932-fullmac wifi.backend "$conf") == "iwd" ]] || fail 'the MT7932 keeps the iwd backend'
[[ $(device_value mt7932-fullmac wifi.iwd.autoconnect "$conf") == "false" ]] || fail 'NetworkManager autoconnects the MT7932'
pass 'NetworkManager autoconnects the MT7932'

for driver in brcmfmac brcmfmac_wcc; do
  [[ -z $(device_value "$driver" wifi.iwd.autoconnect "$conf") ]] || fail "$driver keeps iwd's autoconnect"
done
pass "Broadcom Wi-Fi keeps iwd's autoconnect"

# The model refuses what it cannot answer, rather than passing it.
printf '[device]\nwifi.backend=iwd\n[device-x]\nmatch-device=driver:mt7932-fullmac\nstop-match=yes\nwifi.iwd.autoconnect=false\n' >"$work/stop-match.conf"
[[ $(device_value mt7932-fullmac wifi.backend "$work/stop-match.conf") == "UNSUPPORTED" ]] || fail 'stop-match is refused'
printf '[device]\nwifi.backend=iwd\n[device-x]\nwifi.iwd.autoconnect=false\nmatch-device=driver:mt7932-fullmac\n' >"$work/order.conf"
[[ $(device_value mt7932-fullmac wifi.iwd.autoconnect "$work/order.conf") == "false" ]] || fail 'a key before match-device still applies'
pass 'the model refuses stop-match and ignores key order'
