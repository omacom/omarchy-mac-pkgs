#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
dropin="$work/root/usr/lib/systemd/system/speakersafetyd.service.d/50-omarchy-mac-card.conf"
[[ -f $dropin ]] || fail 'the speaker safety drop-in is staged'
# systemd reads ExecStartPre only from [Service].
pre=$(awk '/^\[/ { section = $0 } section == "[Service]" && /^ExecStartPre=/ { print }' "$dropin")
[[ $pre == 'ExecStartPre=-/usr/bin/udevadm settle --timeout=10' ]] ||
  fail 'speaker safety waits for the udev queue through a non-fatal hook in [Service]' "(${pre:-none})"
# The preset stays the one enabler.
grep -qx 'enable speakersafetyd.service' "$work/root/usr/lib/systemd/system-preset/80-omarchy-mac-audio.preset" || fail 'the preset still enables speakersafetyd'
pass 'speaker safety waits for the udev queue before its first start, and the preset still enables it'

# Arch's speakersafetyd.service lines that matter here, staged with stub commands so
# the result never depends on the host. verify warns about a setting systemd ignores
# but still exits 0, so any output fails, unless a trivial unit fails too, as in
# emulated containers.
stage="$work/root"
stub_systemd_boot_targets "$stage"
mkdir -p "$stage/usr/bin"
for command in speakersafetyd udevadm sh; do
  printf '#!/bin/sh\nexit 0\n' >"$stage/usr/bin/$command"
  chmod +x "$stage/usr/bin/$command"
done
printf '[Unit]\nDescription=Speaker Protection Daemon\n\n[Service]\nType=simple\nExecStart=/usr/bin/speakersafetyd\n' \
  >"$stage/usr/lib/systemd/system/speakersafetyd.service"
printf '[Service]\nExecStart=/usr/bin/sh -c true\n' >"$stage/usr/lib/systemd/system/probe.service"
if verify=$(systemd-analyze --root="$stage" verify --man=no /usr/lib/systemd/system/speakersafetyd.service 2>&1) && [[ -z $verify ]]; then
  pass 'systemd accepts speakersafetyd with the drop-in without warnings'
elif probe=$(systemd-analyze --root="$stage" verify --man=no /usr/lib/systemd/system/probe.service 2>&1) && [[ -z $probe ]]; then
  fail 'systemd accepts speakersafetyd with the drop-in without warnings' "$verify"
else
  pass 'systemd-analyze cannot verify units here; drop-in verification not run'
fi
