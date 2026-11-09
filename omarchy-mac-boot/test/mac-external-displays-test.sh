#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# While the boot splash runs on a laptop's built-in screen, the Apple display
# card's external connectors are held off; they come on for the desktop.
FILES=$ROOT/files
SCRIPT=$FILES/usr/lib/omarchy/mac-boot/external-displays
LID=$FILES/usr/lib/omarchy/mac-boot/lid-state
FB_GEOMETRY=$FILES/usr/lib/omarchy/mac-boot/fb-geometry
RULES=$FILES/usr/lib/udev/rules.d/70-omarchy-mac-external-displays.rules
UNIT=$FILES/usr/lib/systemd/system/omarchy-mac-external-displays.service

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# An M2 Max: the built-in panel, HDMI and three USB-C ports on card2, the
# boot framebuffer on card0.
new_mac() {
  sys=$tmp/sys
  rm -rf "$sys" "$tmp/run" "$tmp/bin"
  local connector
  for connector in card2-eDP-1 card2-HDMI-A-1 card2-USB-1 card2-USB-2 card2-USB-3 card0-Unknown-1; do
    mkdir -p "$sys/class/drm/$connector"
    : >"$sys/class/drm/$connector/status"
  done
  mkdir -p "$sys/class/drm/card2" "$sys/firmware/devicetree/base"
  : >"$sys/class/drm/card2/uevent"
  printf 'laptop\0' >"$sys/firmware/devicetree/base/chassis-type"
  echo 01234567-89ab-cdef-0123-456789abcdef >"$tmp/uuid"
  mkdir -p "$tmp/bin"
  printf '#!/bin/bash\n[[ -e %q ]]\n' "$tmp/splash" >"$tmp/bin/plymouth"
  printf '#!/bin/bash\n[[ -s %q ]] && cat %q\n' "$tmp/lid" "$tmp/lid" >"$tmp/bin/lid-state"
  printf '#!/bin/bash\necho "$*" >>%q\n' "$tmp/journal" >"$tmp/bin/logger"
  chmod +x "$tmp/bin/plymouth" "$tmp/bin/lid-state" "$tmp/bin/logger"
  rm -f "$tmp/journal"
  : >"$tmp/splash"
  echo open >"$tmp/lid"
}

# Its kernel console: fb0 on the display subsystem, sized as the card came up
# with a 3440x1440 monitor lit beside the 3456x2234 panel (notch rows shown),
# in a buffer as wide as the widest display and as tall as the tallest. fb1
# belongs to another device.
with_console() {
  mkdir -p "$sys/devices/soc/display-subsystem" "$sys/devices/soc/framebuffer" "$sys/class/graphics/fb0" "$sys/class/graphics/fb1" "$tmp/fb"
  ln -sfn ../../../devices/soc/display-subsystem "$sys/class/drm/card2/device"
  ln -sfn ../../../devices/soc/display-subsystem "$sys/class/graphics/fb0/device"
  ln -sfn ../../../devices/soc/framebuffer "$sys/class/graphics/fb1/device"
  printf '3456x2234\n3456x2160\n1728x1117\n' >"$sys/class/drm/card2-eDP-1/modes"
  echo 5120,2234 >"$sys/class/graphics/fb0/virtual_size"
  echo "3440 1440" >"$tmp/fb/fb0"
  echo "3456 2160" >"$tmp/fb/fb1"
  rm -f "$tmp/fb-refuses"
  printf '#!/bin/bash\nif (( $# == 1 )); then cat %q/"$1"; else [[ ! -e %q ]] && echo "$2 $3" >%q/"$1"; fi\n' \
    "$tmp/fb" "$tmp/fb-refuses" "$tmp/fb" >"$tmp/bin/fb-geometry"
  chmod +x "$tmp/bin/fb-geometry"
}
console() { cat "$tmp/fb/${1:-fb0}"; }

displays() {
  OMARCHY_SYSFS=$sys OMARCHY_MAC_DISPLAYS_STATE=$tmp/run OMARCHY_UUID_SOURCE=$tmp/uuid OMARCHY_FB_GEOMETRY=$tmp/bin/fb-geometry \
    OMARCHY_PLYMOUTH=$tmp/bin/plymouth OMARCHY_LID_STATE=$tmp/bin/lid-state OMARCHY_LOGGER=$tmp/bin/logger bash "$SCRIPT" "$@"
}

status() { cat "$sys/class/drm/$1/status"; }
externals() { printf '%s ' "$(status card2-HDMI-A-1)" "$(status card2-USB-1)" "$(status card2-USB-2)" "$(status card2-USB-3)"; }
untouched() { [[ -z $(status card2-eDP-1) && -z $(status card0-Unknown-1) ]]; }

# ── hold ───────────────────────────────────────────────────────────────────
new_mac
displays hold card2 || fail "hold succeeds"
[[ $(externals) == "off off off off " ]] || fail "an open laptop under the splash holds every external connector off: $(externals)"
untouched || fail "the built-in panel and other cards are never held"
[[ $(<"$tmp/run/external-displays-held") == $'card2-HDMI-A-1\ncard2-USB-1\ncard2-USB-2\ncard2-USB-3' ]] ||
  fail "hold records what it held: $(cat "$tmp/run/external-displays-held")"
[[ $(<"$tmp/journal") == "-t omarchy-mac-external-displays -- held card2's external displays off: HDMI-A-1 USB-1 USB-2 USB-3" ]] ||
  fail "hold logs what it held: $(cat "$tmp/journal")"
displays hold card2 && (( $(wc -l <"$tmp/run/external-displays-held") == 4 )) || fail "a replayed add holds nothing twice"
pass "an open laptop under the splash holds its external displays off"

for case in shut unknown desktop no-chassis no-splash released no-panel bad-name; do
  new_mac
  card=card2
  case $case in
    shut) echo closed >"$tmp/lid" ;;
    unknown) : >"$tmp/lid" ;;
    desktop) printf 'desktop\0' >"$sys/firmware/devicetree/base/chassis-type" ;;
    no-chassis) rm "$sys/firmware/devicetree/base/chassis-type" ;;
    no-splash) rm "$tmp/splash" ;;
    released) mkdir -p "$tmp/run" && : >"$tmp/run/external-displays-released" ;;
    no-panel) rm -r "$sys/class/drm/card2-eDP-1" ;;
    bad-name) card='card2;rm' ;;
  esac
  displays hold "$card" || fail "hold succeeds ($case)"
  [[ $(externals) == "    " && ! -s $tmp/run/external-displays-held ]] || fail "hold changes nothing ($case): $(externals)"
  case $case in
    shut) why="the lid is closed" ;;
    unknown) why="the lid is unknown" ;;
    desktop | no-chassis) why="this Mac is not a laptop" ;;
    no-splash) why="no splash is running" ;;
    released) why="the splash is over" ;;
    no-panel) why="it has no built-in panel" ;;
    bad-name) why="" ;;
  esac
  if [[ -n $why ]]; then
    [[ $(<"$tmp/journal") == "-t omarchy-mac-external-displays -- not holding card2's external displays: $why" ]] ||
      fail "hold logs why it held nothing ($case): $(cat "$tmp/journal" 2>/dev/null)"
  else
    [[ ! -e $tmp/journal ]] || fail "a bad card name is ignored silently"
  fi
done
pass "a shut or unknown lid, a desktop Mac, no splash, a finished splash or no built-in panel holds nothing"

# ── release ────────────────────────────────────────────────────────────────
new_mac
displays hold card2
echo detect-by-owner >"$sys/class/drm/card0-Unknown-1/status"
displays release >"$tmp/out" || fail "release succeeds"
[[ $(externals) == "detect detect detect detect " ]] || fail "release turns every held connector back on: $(externals)"
[[ -z $(status card2-eDP-1) && $(status card0-Unknown-1) == detect-by-owner ]] || fail "release touches only what hold held"
[[ $(<"$sys/class/drm/card2/uevent") == "change 01234567-89ab-cdef-0123-456789abcdef OMARCHYMACDISPLAYS=1" ]] ||
  fail "release sends the card one synthetic change: $(cat "$sys/class/drm/card2/uevent")"
[[ $(sed -n 's/^change [^ ]* //p' "$sys/class/drm/card2/uevent") =~ ^[A-Za-z0-9]+=[A-Za-z0-9]+$ ]] ||
  fail "the synthetic uevent's argument is alphanumeric, or the kernel refuses it"
[[ -e $tmp/run/external-displays-released && ! -e $tmp/run/external-displays-held ]] || fail "release marks the splash over"
grep -Fxq 'omarchy-mac-external-displays: turned the external displays on card2 back on' "$tmp/out" || fail "release logs what it did"
displays hold card2 && [[ $(externals) == "detect detect detect detect " ]] || fail "a card that appears after the release is not held"
pass "release turns the held displays on and hotplugs their card"

new_mac
displays release >/dev/null && [[ ! -s $sys/class/drm/card2/uevent && -e $tmp/run/external-displays-released ]] ||
  fail "release without anything held only marks the splash over"
new_mac
displays hold card2
chmod a-w "$sys/class/drm/card2-USB-2/status"
if displays release >/dev/null 2>"$tmp/err"; then fail "a connector that cannot be turned on fails the release"; fi
[[ $(externals) == "detect detect off detect " ]] || fail "the other connectors are still turned on: $(externals)"
[[ $(<"$tmp/run/external-displays-held") == card2-USB-2 ]] || fail "the connector stays held for a restart of the unit"
grep -Fq 'could not turn card2-USB-2 back on' "$tmp/err" || fail "the failure names the connector"
chmod u+w "$sys/class/drm/card2-USB-2/status"
displays release >/dev/null && [[ $(externals) == "detect detect detect detect " && ! -e $tmp/run/external-displays-held ]] ||
  fail "a restart turns the rest on"
new_mac
displays hold card2
rm -r "$sys/class/drm/card2"
if displays release >/dev/null 2>"$tmp/err"; then fail "a card that cannot be signalled fails the release"; fi
[[ $(externals) == "detect detect detect detect " ]] || fail "the connectors are still turned on"
grep -Fq 'could not signal card2' "$tmp/err" || fail "the failure names the card"
pass "release reports what it could not do"

# ── console ────────────────────────────────────────────────────────────────
# The kernel console was sized as the card came up, to the smallest display
# lit then (3440x1440 here): owner setup on tty1 filled only the top two thirds
# of the panel. Once the splash has quit, while the externals are held, it is
# fitted to the panel; the release gives it back the kernel's size.
new_mac
with_console
displays hold card2 || fail "hold succeeds with a console"
[[ $(console) == "3440 1440" ]] || fail "the hold leaves the console alone: $(console)"
displays fit || fail "fit succeeds under the splash"
[[ $(console) == "3440 1440" && ! -e $tmp/run/console-fitted ]] ||
  fail "a fit under the splash changes nothing (the kernel console puts tty1's size back as Plymouth hands it over): $(console)"
grep -Fxq -- "-t omarchy-mac-external-displays -- not fitting the console while the splash runs" "$tmp/journal" ||
  fail "a fit under the splash says so: $(cat "$tmp/journal")"
rm "$tmp/splash"
displays fit || fail "fit succeeds once the splash has quit"
[[ $(console) == "3456 2234" ]] || fail "fit fills the panel: $(console)"
[[ $(console fb1) == "3456 2160" ]] || fail "another device's console is left alone"
[[ $(<"$tmp/run/console-fitted") == "fb0 3440 1440" ]] || fail "fit records the kernel's size: $(cat "$tmp/run/console-fitted")"
grep -Fxq -- "-t omarchy-mac-external-displays -- fitted the console on fb0 to the built-in panel: 3440x1440 to 3456x2234" "$tmp/journal" ||
  fail "fit logs what it did: $(cat "$tmp/journal")"
echo "3440 1440" >"$tmp/fb/fb0"
displays fit && [[ $(console) == "3456 2234" && $(<"$tmp/run/console-fitted") == "fb0 3440 1440" ]] ||
  fail "a later fit fills the panel again and keeps the kernel's size for the release"
displays release >"$tmp/out" || fail "release succeeds with a fitted console"
[[ $(console) == "3440 1440" && ! -e $tmp/run/console-fitted ]] || fail "release gives the console back the kernel's size: $(console)"
grep -Fxq 'omarchy-mac-external-displays: gave the console on fb0 back its 3440x1440' "$tmp/out" || fail "release logs the restore"
displays fit && [[ $(console) == "3440 1440" ]] || fail "a console is not fitted after the release"
pass "once the splash has quit, a held panel's console fills it until the release"

for case in nothing-held released same-size clipped refused unreadable no-mode no-console; do
  new_mac
  with_console
  expect="3440 1440"
  case $case in
    nothing-held) echo closed >"$tmp/lid" ;;
    released) ;;
    same-size) echo "3456 2234" >"$tmp/fb/fb0" && expect="3456 2234" ;;
    clipped) echo 4000,2160 >"$sys/class/graphics/fb0/virtual_size" && expect="3456 2160" ;;
    refused) : >"$tmp/fb-refuses" ;;
    unreadable) echo garbage >"$tmp/fb/fb0" && expect=garbage ;;
    no-mode) : >"$sys/class/drm/card2-eDP-1/modes" ;;
    no-console) rm "$sys/class/graphics/fb0/device" ;;
  esac
  displays hold card2 || fail "hold succeeds ($case)"
  [[ $case != released ]] || : >"$tmp/run/external-displays-released"
  rm "$tmp/splash"
  displays fit || fail "fit succeeds ($case)"
  [[ $(console) == "$expect" ]] || fail "the console is $expect ($case): $(console)"
  case $case in
    clipped) [[ -e $tmp/run/console-fitted ]] || fail "a clipped fit is recorded" ;;
    *) [[ ! -e $tmp/run/console-fitted ]] || fail "nothing is recorded to restore ($case)" ;;
  esac
  case $case in
    refused) why="could not fit the console on fb0 to the built-in panel (3456x2234)" ;;
    unreadable) why="not fitting the console on fb0: its size can't be read" ;;
    no-mode) why="not fitting the console on fb0: the built-in panel has no mode" ;;
    *) why="" ;;
  esac
  [[ -z $why ]] || grep -Fxq -- "-t omarchy-mac-external-displays -- $why" "$tmp/journal" ||
    fail "the journal says why ($case): $(cat "$tmp/journal")"
done
pass "a console is fitted only to a held panel, inside its buffer, and left alone when it can't be"

new_mac
with_console
displays hold card2
rm "$tmp/splash"
displays fit
echo "3440 1440" >"$tmp/fb/fb0"
: >"$tmp/fb-refuses"
displays fit && [[ $(<"$tmp/run/console-fitted") == "fb0 3440 1440" ]] || fail "a refused later fit keeps the kernel's size on record"
if displays release >/dev/null 2>"$tmp/err"; then fail "a console that refuses its own size back fails the release"; fi
grep -Fq 'could not give the console on fb0 back its 3440x1440' "$tmp/err" || fail "the failure names the console"
[[ $(externals) == "detect detect detect detect " ]] || fail "the displays still come back on"
pass "release reports a console it could not restore"

# The helper's own checks; a real framebuffer is checked on hardware.
fbg() { OMARCHY_DEV=$tmp/fbdev perl "$FB_GEOMETRY" "$@"; }
mkdir -p "$tmp/fbdev"
: >"$tmp/fbdev/fb0"
for args in "" "fb0;rm" "fb0 3456" "fb0 0 2234" "fb0 3456x2234 1" "fb0 999999 1"; do
  # shellcheck disable=SC2086
  if fbg $args 2>/dev/null; then status=0; else status=$?; fi
  (( status == 2 )) || fail "fb-geometry refuses '$args' as usage ($status)"
done
fbg fb0 >/dev/null && fail "a file that isn't a framebuffer can't be read"
fbg fb0 3456 2234 && fail "a file that isn't a framebuffer can't be set"
fbg fb9 >/dev/null && fail "a missing framebuffer can't be read"
[[ -x $FB_GEOMETRY ]] && perl -c "$FB_GEOMETRY" 2>/dev/null || fail "fb-geometry is executable and parses"
# A framebuffer that answers: ioctl overridden as the kernel would answer it
# (Perl returns "0 but true" for a 0 return), so the success path and the
# struct offsets run without a real /dev/fb.
mkdir -p "$tmp/perl"
cat >"$tmp/perl/FakeFb.pm" <<'PERL'
package FakeFb;
BEGIN {
  *CORE::GLOBAL::ioctl = sub {
    my ($fh, $request) = @_;
    my @var = (0) x 40;
    if ($request == 0x4600) {
      @var[0 .. 6] = (3440, 1440, 5120, 2234, 7, 9, 32);
      $_[2] = pack 'L40', @var;
      return '0 but true';
    }
    if ($request == 0x4601 && length $_[2] == 160) {
      @var = unpack 'L40', $_[2];
      open my $out, '>', $ENV{FAKE_FB_PUT} or die;
      print $out "@var[0 .. 6] $var[21]\n";
      return '0 but true';
    }
    return undef;
  };
}
1;
PERL
fake_fbg() { OMARCHY_DEV=$tmp/fbdev FAKE_FB_PUT=$tmp/fb-put perl -I"$tmp/perl" -MFakeFb "$FB_GEOMETRY" "$@"; }
[[ $(fake_fbg fb0) == "3440 1440" ]] || fail "fb-geometry prints xres and yres: $(fake_fbg fb0)"
fake_fbg fb0 3456 2234 || fail "fb-geometry succeeds when the framebuffer takes the size"
[[ $(<"$tmp/fb-put") == "3456 2234 5120 2234 0 0 32 64" ]] ||
  fail "fb-geometry sets xres and yres, keeps the buffer, clears the pan and activates every console: $(cat "$tmp/fb-put")"
grep -Fq 'my $var = "\0" x 160;' "$FB_GEOMETRY" || fail "struct fb_var_screeninfo is 40 words (160 bytes)"
pass "fb-geometry takes a framebuffer name and a size, and fails on anything else"

# ── lid ────────────────────────────────────────────────────────────────────
# The lid comes from the kernel's switch, not logind, which can start after
# the card appears. Reading a real switch is checked on hardware.
lid() { OMARCHY_SYSFS=$tmp/lsys OMARCHY_DEV=$tmp/ldev perl "$LID"; }
rm -rf "$tmp/lsys" "$tmp/ldev"
mkdir -p "$tmp/ldev/input"
out=$(lid) && fail "no input devices: the lid is unknown"
[[ -z $out ]] || fail "an unknown lid prints nothing: $out"
mkdir -p "$tmp/lsys/class/input/input0/capabilities" "$tmp/lsys/class/input/input0/event0"
echo 0 >"$tmp/lsys/class/input/input0/capabilities/sw"
lid >/dev/null && fail "a device without a lid switch is not a lid"
mkdir -p "$tmp/lsys/class/input/input3/capabilities" "$tmp/lsys/class/input/input3/event3"
echo "10 1" >"$tmp/lsys/class/input/input3/capabilities/sw"
lid >/dev/null && fail "a lid switch without its device node is unknown"
: >"$tmp/ldev/input/event3"
out=$(lid) && fail "a lid switch that won't answer EVIOCGSW is unknown"
[[ -z $out ]] || fail "a switch that can't be read prints nothing: $out"
[[ -x $LID ]] && perl -c "$LID" 2>/dev/null || fail "the lid reader is executable and parses"
(( 0x8008451b == (2 << 30 | 8 << 16 | 0x45 << 8 | 0x1b) )) || fail "EVIOCGSW reads 8 bytes"
pass "the lid is read from the kernel's switch, unknown when it can't be"

# ── wiring ─────────────────────────────────────────────────────────────────
[[ -x $SCRIPT ]] && bash -n "$SCRIPT" || fail "the script is executable and parses"
grep -Fxq 'ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="apple-drm", RUN+="/usr/lib/omarchy/mac-boot/external-displays hold %k"' "$RULES" ||
  fail "the Apple display card is held as it appears"
for unit in omarchy-provision-owner omarchy-drive-recover; do
  grep -Fxq 'ExecStartPre=-/usr/lib/omarchy/mac-boot/external-displays fit' \
    "$FILES/usr/lib/systemd/system/$unit.service.d/30-omarchy-mac-console-fit.conf" ||
    fail "$unit fits the console after its own ExecStartPre has quit the splash"
done
! grep -q 'external-displays fit' "$RULES" || fail "udev never fits the console: the splash still holds tty1 then"
FIRST_BOOT=$FILES/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot
take=$(sed -n '/^take_console()/,/^}/p' "$FIRST_BOOT")
quit_at=$(grep -n 'plymouth quit' <<<"$take" | cut -d: -f1)
fit_at=$(grep -nF '"$external_displays" fit' <<<"$take" | cut -d: -f1)
[[ -n $quit_at && -n $fit_at ]] && (( fit_at > quit_at )) ||
  fail "first boot's failure screen fits the console after quitting the splash"
grep -Fxq 'ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{SYNTH_ARG_OMARCHYMACDISPLAYS}=="1", ENV{HOTPLUG}="1"' "$RULES" ||
  fail "the release's synthetic change is a hotplug (aquamarine rescans on HOTPLUG=1 only)"
grep -Fxq 'After=plymouth-quit.service plymouth-quit-wait.service omarchy-provision-owner.service omarchy-drive-recover.service' "$UNIT" ||
  fail "the release waits for the splash, which first boot holds, and for owner setup or a password reset on tty1"
grep -Fxq 'Before=display-manager.service sddm.service' "$UNIT" || fail "the release runs before the display manager"
grep -Fxq 'ExecStart=/usr/lib/omarchy/mac-boot/external-displays release' "$UNIT" || fail "the unit runs the release"
[[ $(readlink "$FILES/usr/lib/systemd/system/multi-user.target.wants/omarchy-mac-external-displays.service") == ../omarchy-mac-external-displays.service ]] ||
  fail "multi-user.target pulls the release in without an enable step"
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$tmp/units"
  cp "$UNIT" "$tmp/units/"
  mkdir -p "$tmp/probe"
  printf '[Unit]\nDefaultDependencies=no\n[Service]\nType=oneshot\nExecStart=%s\n' "$SCRIPT" >"$tmp/probe/probe.service"
  if probe_out=$(systemd-analyze verify --man=no "$tmp/probe/probe.service" 2>&1) && [[ -z $probe_out ]]; then
    systemd-analyze verify --man=no "$tmp/units/omarchy-mac-external-displays.service" 2>"$tmp/verify" ||
      ! grep -v -e 'not found' -e 'not executable' -e 'Cannot add dependency' "$tmp/verify" | grep -q . ||
      fail "the unit verifies: $(cat "$tmp/verify")"
  else
    echo 'ok - systemd-analyze cannot verify units here; unit verification not run'
  fi
fi
pass "the udev rule and the desktop release are wired"
