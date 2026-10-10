#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

require_command node

# omarchy-mac fills Omarchy's platform root with the Mac's hardware data: the
# keybindings menu's key names, the notch the bar keeps clear of, and the
# backlight and DDC choices. The runtime carries none of them.

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
runtime=${OMARCHY_TEST_RUNTIME:-$ROOT}
"$MAC/install" "$tmpdir/pkg" >/dev/null
platform_root=$tmpdir/pkg/usr/share/omarchy-platform

mkdir -p "$tmpdir/apple-bin"
for predicate in omarchy-hw-aarch64-apple omarchy-hw-apple-silicon; do
  printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/$predicate"
  chmod +x "$tmpdir/apple-bin/$predicate"
done

[[ ! -e $platform_root/hypr ]] || fail "omarchy-mac ships no Hyprland files; Omarchy's own config carries the Mac's binds"

# The keybindings menu shows the brightness keys as the F1 and F2 they are.
[[ $(<"$platform_root/key-names") == $'XF86MonBrightnessUp F2\nXF86MonBrightnessDown F1' ]] ||
  fail "omarchy-mac names the brightness keys F2 and F1"
grep -Fq /usr/share/omarchy-platform/key-names "$runtime/bin/omarchy-menu-keybindings" || fail "the keybindings menu reads the platform's key names"
pass "the keybindings menu names the Mac's brightness keys as its F-keys"

# The bar keeps clear of each MacBook panel's notch.
CUTOUTS="$platform_root/display-cutouts.json" RUNTIME="$runtime" node <<'JS'
const fs = require('fs')
const model = require(process.env.RUNTIME + '/shell/plugins/bar/BarModel.js')
const cutouts = model.parseCutouts(fs.readFileSync(process.env.CUTOUTS, 'utf8'))
const expect = (ok, what) => { if (!ok) { console.error('not ok - ' + what); process.exit(1) } }
expect(cutouts.length === 4, 'four MacBook panels')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1728, 1117, 2, 0) === 32, '16" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1512, 982, 2, 0) === 32, '14" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1280, 832, 2, 0) === 28, 'MacBook Air 13.6" at scale 2: 28 px')
expect(model.notchFloor(cutouts, 'top', 'DP-1', 1728, 1117, 2, 0) === 0, 'external monitors keep no floor')
expect(model.notchFloor(cutouts, 'bottom', 'eDP-1', 1728, 1117, 2, 0) === 0, 'a bottom bar keeps no floor')
expect(model.centerBesideRight(cutouts, 'top', 'eDP-1', 1728, 1117, 2), 'the center section moves beside the right')
JS
pass "the bar keeps clear of the notch on every MacBook panel omarchy-mac describes"

# The built-in panel's backlight is the Retina panel's, never the Touch Bar's:
# an older runtime knows that itself, one with the platform root reads it from
# omarchy-mac's displays.conf. The copy reads a staged root in place of the
# fixed one.
backlights=$tmpdir/backlight
mkdir -p "$backlights/display-pipe" "$backlights/228600000.dsi.0" "$backlights/apple-panel-bl"
pick() {
  sed "s|/usr/share/omarchy-platform|$1|g" "$runtime/bin/omarchy-hw-display" >"$tmpdir/omarchy-hw-display"
  OMARCHY_BACKLIGHT_PATH=$backlights bash "$tmpdir/omarchy-hw-display"
}
[[ $(pick "$platform_root") == apple-panel-bl ]] || fail "a Mac's panel backlight is apple-panel-bl" "$(pick "$platform_root")"
if grep -qF /usr/share/omarchy-platform "$runtime/bin/omarchy-hw-display"; then
  [[ $(pick "$tmpdir/none") != apple-panel-bl ]] || fail "the runtime alone knows no Mac backlight; displays.conf names it"
fi
rmdir "$backlights/apple-panel-bl"
! pick "$platform_root" >/dev/null || fail "a Touch Bar backlight never stands in for the panel's" "$(pick "$platform_root")"
pass "a Mac dims its Retina panel, never the Touch Bar"

# An external monitor on a Mac is probed over DDC only when its connector has a
# ddc node: an older runtime decides that itself, one with the platform root
# from displays.conf. The copy reads a staged root and DRM class.
mkdir -p "$tmpdir/ddc-bin"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/ddc-bin/omarchy-hyprland-monitor-focused-apple"
printf '#!/bin/sh\necho "ddcutil $*" >>"$DDC_LOG"\nexit 1\n' >"$tmpdir/ddc-bin/ddcutil"
chmod +x "$tmpdir/ddc-bin/"*
probes_ddc() {
  local copy=$tmpdir/omarchy-brightness-display run
  sed -e "s|/usr/share/omarchy-platform|$1|g" -e "s|/sys/class/drm|$tmpdir/drm|g" "$runtime/bin/omarchy-brightness-display" >"$copy"
  run=$(mktemp -d "$tmpdir/run.XXXXXX")
  DDC_LOG=$run/ddc.log XDG_RUNTIME_DIR=$run PATH="$tmpdir/ddc-bin:$tmpdir/apple-bin:$runtime/bin:$PATH" bash "$copy" --monitor DP-1 >/dev/null 2>&1 || true
  [[ -s $run/ddc.log ]]
}
mkdir -p "$tmpdir/drm"
! probes_ddc "$platform_root" || fail "a Mac's monitor without a ddc node is not probed over DDC"
mkdir -p "$tmpdir/drm/card0-DP-1/ddc"
probes_ddc "$platform_root" || fail "a Mac's monitor with a ddc node is probed over DDC"
rm -r "$tmpdir/drm/card0-DP-1"
if grep -qF /usr/share/omarchy-platform "$runtime/bin/omarchy-brightness-display"; then
  probes_ddc "$tmpdir/none" || fail "the runtime alone probes every external monitor; displays.conf limits it"
fi
pass "a Mac probes an external monitor over DDC only where its connector has a ddc node"
