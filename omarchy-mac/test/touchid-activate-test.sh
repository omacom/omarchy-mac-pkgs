#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Touch ID reads "ready" only after the first open of /dev/sep-bio, so a udev
# rule starts a unit that opens it once as soon as the kernel publishes it.
"$ROOT/install" "$work/root"
rule=$work/root/usr/lib/udev/rules.d/94-omarchy-mac-touchid.rules
unit=$work/root/usr/lib/systemd/system/omarchy-mac-touchid-activate.service
[[ -f $rule && -f $unit ]] || fail 'the Touch ID rule and unit are staged'
grep -Fxq 'ACTION=="add", SUBSYSTEM=="misc", KERNEL=="sep-bio", TAG+="systemd", ENV{SYSTEMD_WANTS}+="omarchy-mac-touchid-activate.service"' "$rule" ||
  fail 'the rule starts the unit when the Secure Enclave publishes sep-bio, and only then'
[[ $(grep -v '^#' "$rule") != *RUN* ]] || fail 'the rule runs nothing itself'
grep -q "^ExecStart=/usr/bin/sh -c 'true 2>/dev/null </dev/sep-bio; " "$unit" && grep -Fxq 'Type=oneshot' "$unit" &&
  grep -Fxq 'ConditionPathExists=/dev/sep-bio' "$unit" && grep -Fxq 'TimeoutStartSec=15s' "$unit" ||
  fail 'the unit opens /dev/sep-bio once, only where it exists, and within a bounded time'
! grep -q '^StandardInput=' "$unit" || fail 'the platform check does not open /dev/sep-bio as well'
! grep -q '^\[Install\]' "$unit" || fail 'the unit needs no enabling: the rule pulls it in'
pass 'the Touch ID rule and unit are staged, and the rule alone starts the unit'

# The unit's command, run against a fixture node and sysfs, succeeds only when
# Touch ID reads "ready" after it, whether its open worked or the node was busy.
fixture=$work/fixture
mkdir -p "$fixture/bin" "$fixture/apple_sep/396400000.sep/diag"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sleep"
chmod +x "$fixture/bin/sleep"
command=$(sed -n "s|^ExecStart=/usr/bin/sh -c '\(.*\)'$|\1|p" "$unit")
command=${command//\/dev\/sep-bio/$fixture/sep-bio}
command=${command//\/sys\/bus\/platform\/drivers\/apple_sep/$fixture/apple_sep}
activate() {
  printf '%s\n' "$1" >"$fixture/apple_sep/396400000.sep/diag/touchid"
  PATH="$fixture/bin:$PATH" sh -c "$command" 2>/dev/null
}
touch "$fixture/sep-bio"
activate ready || fail 'an open that leaves Touch ID ready succeeds'
! activate not-ready || fail 'an open that leaves Touch ID not ready fails'
rm "$fixture/sep-bio"
activate ready || fail 'a node busy with a Touch ID that is ready succeeds'
! activate not-ready || fail 'a node that cannot be opened, with Touch ID not ready, fails'
[[ $(PATH="$fixture/bin:$PATH" sh -c "$command" 2>&1) == 'Touch ID did not read ready' ]] ||
  fail 'a unit that fails says why in its journal'
pass 'the unit succeeds only when Touch ID reads ready, as the detector checks'

# The update that installs the rule finds /dev/sep-bio already there, so a
# pacman hook starts the unit itself rather than waiting for a reboot.
hook=$work/root/usr/share/libalpm/hooks/90-omarchy-mac-touchid.hook
[[ -f $hook ]] || fail 'the Touch ID pacman hook is staged'
grep -Fxq 'Target = usr/lib/udev/rules.d/94-omarchy-mac-touchid.rules' "$hook" &&
  grep -Fxq 'Operation = Install' "$hook" && grep -Fxq 'Operation = Upgrade' "$hook" &&
  grep -Fxq 'When = PostTransaction' "$hook" &&
  grep -Fxq "Exec = /usr/bin/sh -c 'systemd-detect-virt --quiet --chroot || ! systemd-notify --booted || systemctl --quiet start omarchy-mac-touchid-activate.service'" "$hook" ||
  fail 'the hook starts the unit after the transaction that installs or updates the rule'
target=$(sed -n 's/^Target = //p' "$hook")
[[ -f $work/root/$target ]] || fail "the hook's target is the staged rule" "$target"
pass 'an install or update activates Touch ID in the same session'

if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --no-style "$rule" >/dev/null || fail 'udevadm accepts the rule'
  pass 'udevadm accepts the Touch ID rule'
fi
# Verified inside the staged root, whose stub commands stand in for the
# runtime's platform check, so the result never depends on the host.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon sh; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/omarchy-mac-touchid-activate.service 2>"$work/verify" ||
    fail 'systemd accepts the unit' "$(cat "$work/verify")"
  pass 'systemd accepts the Touch ID unit'
fi
