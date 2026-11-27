#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$ROOT"/install "$work/root"
helper="$work/root/usr/lib/omarchy-mac/speaker-safety-profile"
dropin="$work/root/usr/lib/systemd/system/speakersafetyd.service.d/50-omarchy-mac-profile.conf"
grep -qx 'ExecCondition=/usr/lib/omarchy-mac/speaker-safety-profile' "$dropin" ||
  fail 'the package gates speakersafetyd on its profile'
[[ -x $helper ]] || fail 'the profile gate is executable'
pass 'the package ships the speakersafetyd profile gate'

# speakersafetyd reads apple/j614.conf for apple,j614c, and apple/j123.conf for apple,j123ab.
mkdir -p "$work/bin" "$work/tree" "$work/profiles/apple"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
chmod +x "$work/bin/"*
touch "$work/profiles/apple/j616.conf" "$work/profiles/apple/j180.conf" "$work/profiles/apple/j123.conf"
gate() {
  OMARCHY_MAC_SPEAKER_TREE=$work/tree OMARCHY_MAC_SPEAKER_PROFILES=$work/profiles PATH="$work/bin:$PATH" "$helper"
}
mac() {
  printf '%s\0apple,arm-platform\0' "$1" >"$work/tree/compatible"
  gate
}
mac apple,j616c || fail 'a Mac with a profile runs speakersafetyd'
mac apple,j180d || fail 'the letter suffix is dropped as the daemon drops it'
mac apple,j123ab || fail 'a suffix of several letters is dropped as well'
! mac apple,j614c || fail 'a Mac without a profile skips speakersafetyd'
! mac apple,j700 || fail 'a Mac without a suffix or a profile skips speakersafetyd'
! mac apple || fail 'a compatible without a model skips speakersafetyd'
! PLATFORM=aarch64 mac apple,j616c || fail 'a machine that is not a Mac skips speakersafetyd'
rm "$work/tree/compatible"
! gate || fail 'a Mac the daemon cannot name skips speakersafetyd'
pass 'speakersafetyd runs only where it has a profile, found as the daemon finds it'

if command -v systemd-analyze >/dev/null; then
  stub_systemd_boot_targets "$work/root"
  mkdir -p "$work/root/usr/bin"
  printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/speakersafetyd"
  chmod +x "$work/root/usr/bin/speakersafetyd"
  printf '[Service]\nExecStart=/usr/bin/speakersafetyd\n[Install]\nWantedBy=multi-user.target\n' \
    >"$work/root/usr/lib/systemd/system/speakersafetyd.service"
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/speakersafetyd.service 2>"$work/verify" ||
    fail 'systemd accepts speakersafetyd with the profile gate' "$(cat "$work/verify")"
  systemd-analyze --root="$work/root" cat-config systemd/system/speakersafetyd.service 2>/dev/null |
    grep -qx 'ExecCondition=/usr/lib/omarchy-mac/speaker-safety-profile' ||
    fail 'systemd reads the profile gate into speakersafetyd'
  pass 'systemd accepts speakersafetyd with the profile gate'
fi
