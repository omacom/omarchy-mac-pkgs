#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# pacman's systemd hook runs this after installing or upgrading the package.
tmpfiles() { systemd-tmpfiles --create --root="$1" || fail "systemd-tmpfiles applies the package rules in $1"; }
setting() { sed -n "s/^$2=//p" "$1/etc/mpv/mpv.conf"; }

"$ROOT"/install "$work/fresh"
tmpfiles "$work/fresh"
cmp -s "$work/fresh/etc/mpv/mpv.conf" "$work/fresh/usr/share/omarchy-mac/mpv/mpv.conf" ||
  fail 'a fresh install gets the vendor mpv default'
[[ $(setting "$work/fresh" hwdec) == "vaapi-copy" ]] ||
  fail 'mpv decodes on AVD with copy-back, never zero-copy' "$(setting "$work/fresh" hwdec)"
[[ $(setting "$work/fresh" hwdec-codecs) == "h264,hevc,vp9" ]] ||
  fail 'mpv asks AVD only for the codecs it decodes' "$(setting "$work/fresh" hwdec-codecs)"
[[ $(setting "$work/fresh" vo) == "gpu" && $(setting "$work/fresh" gpu-api) == "opengl" ]] ||
  fail 'mpv draws copied frames with the OpenGL renderer'
[[ $(setting "$work/fresh" gpu-sw) == "yes" ]] ||
  fail 'mpv draws in software on a Mac whose GPU has no driver yet' "$(setting "$work/fresh" gpu-sw)"
pass 'a fresh install decodes H.264, HEVC and VP9 on AVD in mpv, with copy-back and OpenGL, and draws in software without a GPU driver'

# An upgraded Mac already has /etc/mpv from mpv-mpris.
"$ROOT"/install "$work/upgrade"
mkdir -p "$work/upgrade/etc/mpv/scripts"
ln -s /usr/lib/mpv-mpris/mpris.so "$work/upgrade/etc/mpv/scripts/mpris.so"
tmpfiles "$work/upgrade"
[[ $(setting "$work/upgrade" hwdec) == "vaapi-copy" ]] || fail 'an upgrade adds the mpv default'
[[ -L $work/upgrade/etc/mpv/scripts/mpris.so ]] || fail 'an upgrade leaves mpv scripts alone'
pass 'an upgraded install gets the mpv default beside its scripts'

"$ROOT"/install "$work/admin"
mkdir -p "$work/admin/etc/mpv"
printf 'hwdec=no\nprofile=high-quality\n' >"$work/admin/etc/mpv/mpv.conf"
tmpfiles "$work/admin"
[[ $(<"$work/admin/etc/mpv/mpv.conf") == $'hwdec=no\nprofile=high-quality' ]] ||
  fail 'an administrator mpv.conf stays' "$(<"$work/admin/etc/mpv/mpv.conf")"
printf 'hwdec=no\n' >"$work/fresh/etc/mpv/mpv.conf"
tmpfiles "$work/fresh"
[[ $(setting "$work/fresh" hwdec) == "no" ]] || fail 'a later edit survives the next upgrade'
pass 'an administrator mpv.conf, or a later edit, is never overwritten'

# omarchy-mac 0.2.2 and earlier copied a default without gpu-sw, which tmpfiles
# keeps. omarchy-mac-setup-system replaces that copy only while it is untouched.
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo "${PLATFORM:-aarch64-apple}"
STUB
stub_apple_predicate "$work/bin"
printf '#!/bin/bash\necho "Broadcom [14e4:4433]"\n' >"$work/bin/lspci"
printf '#!/bin/bash\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
cat >"$work/released.conf" <<'CONF'
# Omarchy on Apple Silicon: mpv decodes H.264, HEVC and VP9 on the Apple Video
# Decoder and draws with the OpenGL renderer.
#
# vaapi-copy returns each decoded frame to memory, bit for bit what software
# decoding gives. Zero-copy (hwdec=vaapi) turns green through gpu-next, whose
# Vulkan import on Asahi reads the colour plane from the wrong offset, and it
# keeps frames the VA driver invalidates when its decoder closes. OpenGL draws
# the copied frames for about a third of the CPU gpu-next needs here.
#
# systemd-tmpfiles copies this file from /usr/share/omarchy-mac/mpv/mpv.conf when
# /etc/mpv/mpv.conf is missing, and never overwrites it. Your own
# ~/.config/mpv/mpv.conf is read after it and wins: hwdec=no decodes in software,
# vo=gpu-next with gpu-api=auto restores mpv's default renderer.
hwdec=vaapi-copy
hwdec-codecs=h264,hevc,vp9
vo=gpu
gpu-api=opengl
CONF
setup() { "$1/usr/bin/omarchy-mac-setup-system" "$1" >"$work/out" 2>"$work/err" || fail "setup runs in $1" "$(<"$work/err")"; }
released() {
  "$ROOT"/install "$1"
  mkdir -p "$1/etc/mpv/scripts"
  ln -s /usr/lib/mpv-mpris/mpris.so "$1/etc/mpv/scripts/mpris.so"
  install -m644 "$work/released.conf" "$1/etc/mpv/mpv.conf"
}

released "$work/old"
chmod 640 "$work/old/etc/mpv/mpv.conf"
tmpfiles "$work/old"
cmp -s "$work/old/etc/mpv/mpv.conf" "$work/released.conf" || fail 'tmpfiles alone keeps the 0.2.2 copy'
setup "$work/old"
cmp -s "$work/old/etc/mpv/mpv.conf" "$work/old/usr/share/omarchy-mac/mpv/mpv.conf" ||
  fail 'setup replaces an untouched 0.2.2 mpv default'
[[ $(setting "$work/old" gpu-sw) == "yes" ]] || fail 'the replaced default draws in software without a GPU driver'
[[ $(stat -c %a "$work/old/etc/mpv/mpv.conf") == 640 ]] || fail 'the replaced default keeps its mode'
[[ -L $work/old/etc/mpv/scripts/mpris.so ]] || fail 'the replacement leaves mpv scripts alone'
[[ -z $(find "$work/old/etc/mpv" -name '.mpv.conf.*') ]] || fail 'no temporary file is left'
grep -q "Updated $work/old/etc/mpv/mpv.conf" "$work/out" || fail 'the replacement is reported'
cp "$work/old/etc/mpv/mpv.conf" "$work/expected"
setup "$work/old"
cmp -s "$work/old/etc/mpv/mpv.conf" "$work/expected" && ! grep -q 'mpv.conf' "$work/out" ||
  fail 'a second setup run changes and reports nothing' "$(<"$work/out")"
pass 'an untouched 0.2.2 mpv default takes gpu-sw at setup, once'

released "$work/edited"
sed -i 's/^hwdec=vaapi-copy$/hwdec=no/' "$work/edited/etc/mpv/mpv.conf"
cp "$work/edited/etc/mpv/mpv.conf" "$work/expected"
setup "$work/edited"
cmp -s "$work/edited/etc/mpv/mpv.conf" "$work/expected" || fail 'an edited 0.2.2 default stays'
cp "$work/released.conf" "$work/edited/etc/mpv/mpv.conf"
printf '\n' >>"$work/edited/etc/mpv/mpv.conf"
cp "$work/edited/etc/mpv/mpv.conf" "$work/expected"
setup "$work/edited"
cmp -s "$work/edited/etc/mpv/mpv.conf" "$work/expected" || fail 'a 0.2.2 default with one byte added stays'
released "$work/link"
mv "$work/link/etc/mpv/mpv.conf" "$work/link-target"
ln -s "$work/link-target" "$work/link/etc/mpv/mpv.conf"
setup "$work/link"
[[ -L $work/link/etc/mpv/mpv.conf ]] && cmp -s "$work/link-target" "$work/released.conf" ||
  fail 'a link to the 0.2.2 default, and its target, stay'
released "$work/other"
PLATFORM=x86 setup "$work/other"
cmp -s "$work/other/etc/mpv/mpv.conf" "$work/released.conf" || fail 'a machine that is not a Mac is untouched'
rm -r "$work/other/etc/mpv"
setup "$work/other"
[[ ! -e $work/other/etc/mpv ]] || fail 'setup creates no mpv.conf where none exists'
pass 'an edited or linked mpv default, another machine and a missing one are left to tmpfiles and the administrator'
