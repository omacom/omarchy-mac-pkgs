#!/bin/bash
# First boot's hand-off to greetd (omacom/omarchy#20404), with real systemctl
# --root: greetd and SDDM both install as display-manager.service, and greetd
# must take the alias over from an SDDM an older image left enabled.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
first_boot=$ROOT/files/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot
require_command systemctl
real_systemctl=$(command -v systemctl)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# First boot enables units on the live system; here they land in the image root.
cat >"$work/bin/systemctl" <<STUB
#!/bin/bash
exec "$real_systemctl" --root="\$OMARCHY_MAC_FIRST_BOOT_ROOT" "\$@"
STUB
# The runtime's omarchy-system-login, which the pinned runtime predates.
cat >"$work/bin/omarchy-system-login" <<'STUB'
#!/bin/bash
[[ $1 == --root && $3 == --reset ]] || exit 2
mkdir -p "$2/etc/greetd"
echo '[default_session]' >"$2/etc/greetd/config.toml"
STUB
chmod +x "$work/bin/"*

# An image root with this package, owner provisioning and both display managers.
image() {
  local root=$1 unit
  "$ROOT/install" "$root"
  mkdir -p "$root/usr/lib/systemd/system" "$root/usr/share/omarchy/install/provisioning" "$root/var/log"
  for unit in greetd sddm; do
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nAlias=display-manager.service\n' \
      >"$root/usr/lib/systemd/system/$unit.service"
  done
  printf '[Service]\nExecStart=/usr/bin/true\n' >"$root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  printf '#!/bin/bash\n' >"$root/usr/bin/omarchy-provision-owner"
  chmod 755 "$root/usr/bin/omarchy-provision-owner"
}

handoff() {
  env OMARCHY_MAC_FIRST_BOOT_ROOT="$1" PATH="$work/bin:$PATH" \
    bash -c 'source "$1"; stage_provisioning' _ "$first_boot" >/dev/null 2>&1
}

for start in fresh sddm-enabled; do
  root=$work/$start
  image "$root"
  if [[ $start == sddm-enabled ]]; then
    "$real_systemctl" --root="$root" enable sddm.service >/dev/null 2>&1 || fail 'SDDM is enabled first'
  fi
  handoff "$root" || fail "first boot hands off to greetd ($start)" "$(cat "$root/var/log/omarchy-mac-first-boot.log" 2>/dev/null)"
  [[ $(readlink "$root/etc/systemd/system/display-manager.service") == /usr/lib/systemd/system/greetd.service ]] ||
    fail "display-manager.service is greetd ($start)"
  [[ -s $root/etc/greetd/config.toml ]] || fail "greetd's configuration is written ($start)"
done
pass 'first boot enables greetd as the display manager, over an SDDM left enabled'
