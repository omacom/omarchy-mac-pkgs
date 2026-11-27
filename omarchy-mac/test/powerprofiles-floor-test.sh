#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
printf '#!/bin/bash\necho 14e4:4433\n' >"$work/bin/lspci"
chmod +x "$work/bin/"*

root="$work/root"
"$ROOT"/install "$root"
setup="$root/usr/bin/omarchy-mac-setup-system"
unit=omarchy-mac-powerprofiles-floor.service
wants="$root/etc/systemd/system/graphical.target.wants/$unit"
marker="$root/var/lib/omarchy-mac/powerprofiles-floor-configured"
# Arch disables every unit no preset names.
mkdir -p "$root/usr/lib/systemd/system-preset"
echo 'disable *' >"$root/usr/lib/systemd/system-preset/99-default.preset"
floor() { PATH="$work/bin:$PATH" "$setup" "$root" 2>&1; }

[[ -f $root/usr/lib/systemd/system/$unit ]] || fail 'the package ships the floor unit'
grep -qx 'ExecStart=/usr/bin/omarchy-powerprofiles-floor monitor' "$root/usr/lib/systemd/system/$unit" ||
  fail 'the unit runs the runtime command'
grep -qx 'ConditionPathExists=/usr/bin/omarchy-powerprofiles-floor' "$root/usr/lib/systemd/system/$unit" ||
  fail 'the unit is skipped, not failed, without the runtime command'
grep -qx 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$root/usr/lib/systemd/system/$unit" ||
  fail 'the unit runs only on Apple Silicon'
grep -qx 'WantedBy=graphical.target' "$root/usr/lib/systemd/system/$unit" ||
  fail 'the unit is wanted by graphical.target, after power-profiles-daemon, without a cycle'
grep -qx 'Environment=OMARCHY_POWERPROFILES_FLOOR_BALANCED=smallest-core' "$root/usr/lib/systemd/system/$unit" ||
  fail 'balanced floors at the efficiency cores'
pass 'the package ships a floor unit that runs the runtime command'

output=$(floor)
[[ ! -e $wants && ! -e $marker ]] || fail 'setup waits for a runtime with omarchy-powerprofiles-floor'
[[ $output == *"Deferring the CPU frequency floor"* ]] || fail 'setup says it defers the floor' "$output"
pass 'setup defers the floor on a runtime without the command'

# A runtime whose floor cannot follow the efficiency cores would hold them at 768.
printf '#!/bin/bash\n' >"$root/usr/bin/omarchy-powerprofiles-floor"; chmod 755 "$root/usr/bin/omarchy-powerprofiles-floor"
output=$(floor)
[[ ! -e $wants && ! -e $marker ]] || fail 'setup waits for a runtime with the smallest-core floor'
[[ $output == *"cannot follow the efficiency cores"* ]] || fail 'setup says why it waits' "$output"
pass 'setup defers the floor on a runtime without the smallest-core floor'

printf '#!/bin/bash\n# balanced: smallest-core\n' >"$root/usr/bin/omarchy-powerprofiles-floor"
floor >/dev/null
[[ $(readlink "$wants") == "/usr/lib/systemd/system/$unit" && -f $marker ]] || fail 'setup enables the floor and records it'
pass 'setup enables the floor once the runtime has the command'

# A failed enable leaves no marker, so the next run enables it.
rm "$wants" "$marker"
printf '#!/bin/bash\nfor argument in "$@"; do [[ $argument == "enable" ]] && exit 1; done\nexec /usr/bin/systemctl "$@"\n' >"$work/bin/systemctl"
chmod +x "$work/bin/systemctl"
floor >/dev/null 2>&1 || fail 'a failed enable does not abort setup'
[[ ! -e $marker ]] || fail 'a failed enable records nothing'
rm "$work/bin/systemctl"
floor >/dev/null
[[ $(readlink "$wants") == "/usr/lib/systemd/system/$unit" && -f $marker ]] || fail 'a rerun after a failed enable enables the floor'
pass 'a rerun after a failed enable enables the floor'

systemctl --root="$root" disable "$unit" >/dev/null 2>&1
floor >/dev/null
[[ ! -e $wants ]] || fail 'an explicit disable after setup survives'
pass 'an explicit disable after setup survives'

rm "$marker"
ln -s /dev/null "$root/etc/systemd/system/$unit"
floor >/dev/null || fail 'a masked floor unit does not fail setup'
[[ $(readlink "$root/etc/systemd/system/$unit") == /dev/null && ! -e $wants && ! -e $marker ]] || fail 'a masked floor unit stays masked'
pass 'a masked floor unit stays masked'

other="$work/other"
"$ROOT"/install "$other"
install -Dm755 /dev/null "$other/usr/bin/omarchy-powerprofiles-floor"
PLATFORM=aarch64-qualcomm PATH="$work/bin:$PATH" "$other/usr/bin/omarchy-mac-setup-system" "$other" >/dev/null 2>&1
[[ ! -e $other/etc/systemd/system/graphical.target.wants/$unit && ! -e $other/var/lib/omarchy-mac/powerprofiles-floor-configured ]] ||
  fail 'another platform gets no Apple floor'
pass 'another platform gets no Apple floor'

# verify warns about a setting systemd ignores but still exits 0, so any output
# fails, unless a trivial unit fails too, as in emulated containers.
stub_systemd_boot_targets "$other"
install -Dm755 /dev/null "$other/usr/bin/omarchy-hw-apple-silicon"
printf '[Service]\nExecStart=sh -c true\n' >"$other/usr/lib/systemd/system/probe.service"
if verify=$(systemd-analyze --root="$other" verify --man=no "/usr/lib/systemd/system/$unit" 2>&1) && [[ -z $verify ]]; then
  pass 'systemd accepts the floor unit without warnings'
elif probe=$(systemd-analyze --root="$other" verify --man=no /usr/lib/systemd/system/probe.service 2>&1) && [[ -z $probe ]]; then
  fail 'systemd accepts the floor unit without warnings' "$verify"
else
  pass 'systemd-analyze cannot verify units here; floor unit verification not run'
fi
