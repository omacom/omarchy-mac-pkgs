#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/runtime-test.sh"
if (( EUID == 0 )); then
  echo 'skip - staged lifecycle dispatch uses its unprivileged fixture root'
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo apple-silicon
STUB
printf '#!/bin/bash\necho "Broadcom Bluetooth [14e4:5f69]"\n' >"$work/bin/lspci"
chmod +x "$work/bin/"*
stage=$work/root
"$MAC/install" "$stage"
# Bind only the installed filesystem and detector boundaries to the staged root.
sed "s|fixed_path=/usr/local/sbin:/usr/local/bin:/usr/bin|fixed_path=$work/bin:/usr/bin|" \
  "$ROOT/bin/omarchy-lifecycle-dispatch" >"$work/bin/omarchy-lifecycle-dispatch"
entrypoint=$stage/usr/lib/omarchy/mac/setup-system
sed "s|root=\${OMARCHY_MAC_ROOT:-}|root=$stage|" "$entrypoint" >"$work/entrypoint"
install -m755 "$work/entrypoint" "$entrypoint"
chmod +x "$work/bin/omarchy-lifecycle-dispatch"
OMARCHY_LIFECYCLE_ROOT=$stage "$work/bin/omarchy-lifecycle-dispatch" setup-system image-first-boot
unit=omarchy-bluetooth-resume-fix.service
link=$stage/etc/systemd/system/suspend.target.wants/$unit
[[ $(readlink "$link") == /usr/lib/systemd/system/$unit ]] || fail 'runtime setup reaches the vendor Bluetooth recovery unit'
systemctl --root="$stage" disable "$unit" >/dev/null 2>&1
OMARCHY_LIFECYCLE_ROOT=$stage "$work/bin/omarchy-lifecycle-dispatch" setup-system
[[ ! -e $link ]] || fail 'a runtime setup rerun preserves disabled Bluetooth recovery'
pass 'runtime lifecycle dispatch enables Bluetooth recovery once and preserves a later disable'
