#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
if (( $(bash -c 'echo "${BASH_VERSINFO[0]}"') < 5 )); then
  pass "mac-check runs on the Mac's bash 5; skipping under an older bash"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
fixture="$test_tmp/fixture"
kver=7.1.12-2-7-ARCH
uid=$(id -u)
mkdir -p "$stub_bin"

# A healthy M2 Max: Aurora kernel, Limine, a logged-in session. Its device tree is
# where Linux keeps it, and /proc/device-tree links to it. `make_fixture m4` makes
# it a 14-inch M4 Max instead.
make_fixture() {
  rm -rf "$fixture"
  local root=$fixture
  mkdir -p "$root/sys/firmware/devicetree/base" "$root/proc/asound" "$root/usr/lib/modules/$kver" "$root/var/lib/omarchy" \
    "$root/run/user/$uid/hypr/instance1" "$root/boot/efi/EFI/Linux" "$root/boot/efi/m1n1" "$root/.snapshots"
  ln -s ../sys/firmware/devicetree/base "$root/proc/device-tree"
  if [[ ${1:-} == m4 ]]; then
    printf 'apple,j614c\0apple,t6041\0apple,arm-platform\0' >"$root/proc/device-tree/compatible"
    printf 'Apple MacBook Pro (14-inch, M4 Max, 2024)\0' >"$root/proc/device-tree/model"
  else
    printf 'apple,j416c\0apple,t6021\0apple,arm-platform\0' >"$root/proc/device-tree/compatible"
    printf 'Apple MacBook Pro (16-inch, M2 Max, 2023)\0' >"$root/proc/device-tree/model"
  fi
  printf 'laptop\0' >"$root/proc/device-tree/chassis-type"
  printf ' 0 [AppleJ416HPAI  ]: aop_audio - MacBook Pro J416 HPAI\n                      MacBook Pro J416 High-Power Audio Interface\n 1 [AppleJ416      ]: macaudio - MacBook Pro J416\n                      MacBook Pro J416\n' >"$root/proc/asound/cards"
  printf 'cpu 1 2 3\nbtime 1790289337\n' >"$root/proc/stat"
  printf 'linux-aurora\n' >"$root/usr/lib/modules/$kver/pkgbase"
  printf 'kernel\n' >"$root/usr/lib/modules/$kver/vmlinuz"
  printf 'format=1\nsequence=56\ntag=asahi-quattro-59ee15f6\n' >"$root/var/lib/omarchy/asahi-quattro-release"
  printf 'format=1\nlane=rc\n' >"$root/var/lib/omarchy/apple-silicon-aurora-lane"
  : >"$root/run/user/$uid/hypr/instance1/.socket.sock"
  : >"$root/run/user/$uid/pipewire-0"
  : >"$root/run/user/$uid/bus"
  printf 'uki\n' >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
  printf 'limine config\n' >"$root/boot/efi/limine.conf"
  printf 'm1n1 stage 2\n' >"$root/boot/efi/m1n1/boot.bin"
  make_peripherals "${1:-}"
}

# Its ports and peripherals: three labelled USB-C connectors, each behind its own
# controller, with a security key in the first; the GPU, camera, SD card reader,
# keyboard backlight and battery; and Touch ID ready to be turned on. Before the
# M4 Pro and M4 Max the connectors sit on I2C and the controllers and the reader's
# PCIe bus under /soc, the last controller with the older port/endpoint form; on
# them all three sit at the root.
dt_strings() {
  mkdir -p "${1%/*}"
  printf '%s\0' "${@:2}" >"$1"
}
dt_u32() {
  mkdir -p "${1%/*}"
  printf "$(printf '\\x%02x' 0 0 0 "$2")" >"$1"
}
make_peripherals() {
  local root=$fixture tree=$fixture/proc/device-tree index=0 port name controller address endpoint
  local pd=soc/i2c@39b040000/usb-pd@ bus=soc/ reader=soc/pcie@590000000
  local -a ports=("Left Back:702280000:38" "Left Front:b02280000:3f" "Right:f02280000:3b")
  if [[ ${1:-} == m4 ]]; then
    pd=spmi@0/usb-pd@ bus="" reader=pcie@1cb0000000
    ports=("Left Back:382280000:0" "Left Front:38a280000:1" "Right:392280000:2")
  fi
  for port in "${ports[@]}"; do
    IFS=: read -r name controller address <<<"$port"
    name="USB-C $name" endpoint=ports/port@0/endpoint
    [[ -n $bus && $index == 2 ]] && endpoint=port/endpoint
    dt_strings "$tree/$pd$address/connector/compatible" usb-c-connector
    dt_strings "$tree/$pd$address/connector/label" "$name"
    dt_u32 "$tree/$pd$address/connector/ports/port@0/endpoint/remote-endpoint" $((16 + index))
    dt_u32 "$tree/${bus}usb@$controller/$endpoint/phandle" $((16 + index))
    dt_strings "$root/sys/class/typec/port$index/device/of_node/connector/label" "$name"
    printf '[host] device\n' >"$root/sys/class/typec/port$index/data_role"
    index=$((index + 1))
  done
  controller=${ports[0]#*:} controller=${controller%%:*}
  mkdir -p "$root/sys/class/typec/port0-partner" "$root/sys/bus/usb/devices"
  local key=$root/sys/devices/platform/$controller.usb/xhci-hcd.0.auto/usb3/3-1
  mkdir -p "$key"
  printf 'YubiKey OTP+FIDO+CCID\n' >"$key/product"
  printf '12\n' >"$key/speed"
  ln -s "../../../devices/platform/$controller.usb/xhci-hcd.0.auto/usb3/3-1" "$root/sys/bus/usb/devices/3-1"
  ln -s "../../../devices/platform/$controller.usb/xhci-hcd.0.auto/usb3" "$root/sys/bus/usb/devices/usb3"
  dt_strings "$root/sys/class/drm/renderD128/device/of_node/compatible" apple,agx-t6021
  ln -s ../../../../bus/platform/drivers/asahi "$root/sys/class/drm/renderD128/device/driver"
  for name in card0-eDP-1:connected card1-DP-1:disconnected card1-HDMI-A-1:disconnected; do
    mkdir -p "$root/sys/class/drm/${name%%:*}"
    printf '%s\n' "${name#*:}" >"$root/sys/class/drm/${name%%:*}/status"
  done
  dt_strings "$tree/isp@22a000000/compatible" apple,t6020-isp apple,isp
  dt_strings "$root/sys/class/video4linux/video0/device/of_node/compatible" apple,t6020-isp apple,isp
  dt_strings "$tree/$reader/pci@1,0/mmc@0,0/compatible" pci17a0,9755
  mkdir -p "$root/sys/class/mmc_host/mmc0"
  dt_strings "$tree/led-controller/led-0/function" kbd_backlight
  mkdir -p "$root/sys/class/leds/apple::kbd_backlight" "$root/sys/class/power_supply/macsmc-battery" "$root/run/omarchy-mac"
  mkdir -p "$root/sys/class/leds/apple::kbd_backlight/device"
  ln -s ../../../../bus/platform/drivers/leds_pwm "$root/sys/class/leds/apple::kbd_backlight/device/driver"
  printf '128\n' >"$root/sys/class/leds/apple::kbd_backlight/brightness"
  printf '255\n' >"$root/sys/class/leds/apple::kbd_backlight/max_brightness"
  printf 'Battery\n' >"$root/sys/class/power_supply/macsmc-battery/type"
  printf '87\n' >"$root/sys/class/power_supply/macsmc-battery/capacity"
  printf 'Discharging\n' >"$root/sys/class/power_supply/macsmc-battery/status"
  printf '80\n' >"$root/sys/class/power_supply/macsmc-battery/charge_control_end_threshold"
  printf 'available\n' >"$root/run/omarchy-mac/touchid"
}

stub() {
  cat >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}

stub uname <<'SH'
#!/bin/bash
case ${1:-} in
  -m) echo "${TEST_ARCH:-aarch64}" ;;
  -r) echo "${TEST_KVER:-7.1.12-2-7-ARCH}" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
SH
stub pacman <<'SH'
#!/bin/bash
case $1 in
  -Qqo) [[ $2 == */usr/lib/modules/7.1.12-2-7-ARCH/vmlinuz && -e $2 ]] && echo linux-aurora || exit 1 ;;
  -Qq) printf '%s\n' linux-aurora linux-aurora-headers m1n1-aurora uboot-asahi limine omarchy-mac omarchy-mac-boot ;;
  -Q)
    case $2 in
      linux-aurora) echo "linux-aurora 7.1.12.aurora2-7" ;;
      *) echo "$2 1.0-1" ;;
    esac
    ;;
  -Si) [[ ${TEST_KERNEL_REPO:-omarchy} != none ]] && printf 'Repository      : %s\nName            : %s\n' "${TEST_KERNEL_REPO:-omarchy}" "$2" || exit 1 ;;
  *) exit 1 ;;
esac
SH
stub pacman-conf <<'SH'
#!/bin/bash
printf '%s\n' omarchy asahi-alarm core extra alarm
SH
stub sudo <<'SH'
#!/bin/bash
[[ $1 == "-n" ]] && shift
(( ${TEST_SUDO:-1} )) || exit 1
exec "$@"
SH
stub omarchy-apple-silicon-boot-check <<'SH'
#!/bin/bash
echo boot-check >>"$TEST_LOG"
echo "boot-check locale: LC_ALL=${LC_ALL-unset} LANG=${LANG-unset}" >>"$TEST_LOG"
if (( ${TEST_BOOT_CHECK_STATUS:-0} )); then
  echo "Apple Silicon boot check: m1n1/boot.bin on the system ESP is not m1n1 as installed" >&2
  exit 1
fi
echo "Apple Silicon boot check: running linux-aurora 7.1.12-2-7-ARCH from aurora-packages-3caea46 (lane=rc)"
SH
stub omarchy-mac-limine-active <<'SH'
#!/bin/bash
exit 0
SH
stub findmnt <<'SH'
#!/bin/bash
[[ ${*: -1} == */boot/efi ]] && echo vfat
SH
stub systemctl <<'SH'
#!/bin/bash
[[ $* == *--failed* ]] && (( ${TEST_SYSTEMCTL_DOWN:-0} )) && exit 1
[[ $* == *--user* ]] && (( ${TEST_USER_MANAGER_DOWN:-0} )) && exit 1
case "$*" in
  "--failed --no-legend --plain") printf '%s' "${TEST_FAILED_UNITS:-}" ;;
  "--user --failed --no-legend --plain") printf '%s' "${TEST_FAILED_USER_UNITS:-}" ;;
  "show -p LoadState --value omarchy-vendor-firmware.service") echo loaded ;;
  "show -p ActiveState --value omarchy-vendor-firmware.service") echo active ;;
  "show -p Result --value omarchy-vendor-firmware.service") echo success ;;
  "is-active speakersafetyd.service") echo active ;;
  *) exit 1 ;;
esac
SH
stub hyprctl <<'SH'
#!/bin/bash
[[ $HYPRLAND_INSTANCE_SIGNATURE == instance1 ]] || exit 1
shown='{"name":"eDP-1","width":3456,"height":2160,"refreshRate":120.0,"disabled":false}'
if (( ${TEST_SHOWS_DP:-0} )); then
  shown+=',{"name":"DP-1","width":3840,"height":2160,"refreshRate":60.0,"disabled":false}'
else
  shown+=',{"name":"USB-1","width":3440,"height":1440,"refreshRate":59.973,"disabled":false}'
fi
# monitors -j lists what Hyprland shows; monitors all -j also what it keeps disabled.
if [[ $* == "monitors all -j" ]] && (( ${TEST_DISABLED_DP:-0} )); then
  shown+=',{"name":"DP-1","width":3840,"height":2160,"refreshRate":60.0,"disabled":true}'
fi
echo "[$shown]"
SH
stub wpctl <<'SH'
#!/bin/bash
if (( ${TEST_DUMMY_SINK:-0} )); then
  printf '  * node.description = "Dummy Output"\n  * node.name = "auto_null"\n'
else
  printf '  * node.description = "MacBook Pro J416 Speakers"\n  * node.name = "audio_effect.j416-convolver"\n'
fi
SH
stub nmcli <<'SH'
#!/bin/bash
printf 'wlan0:wifi:%s\nlo:loopback:connected (externally)\n' "${TEST_WIFI_STATE:-connected}"
SH
stub NetworkManager <<'SH'
#!/bin/bash
printf '[device]\nwifi.backend=iwd\n'
SH
stub bluetoothctl <<'SH'
#!/bin/bash
printf 'Controller 00:00:00:00:00:00 (public)\n\tPowered: yes\n'
SH
stub timeout <<'SH'
#!/bin/bash
shift
exec "$@"
SH
stub btrfs <<'SH'
#!/bin/bash
[[ -d ${*: -1} ]]
SH
stub snapper <<'SH'
#!/bin/bash
printf 'number\n0\n1\n2\n'
SH
stub omarchy-migrate <<'SH'
#!/bin/bash
exit 1
SH
stub coredumpctl <<'SH'
#!/bin/bash
(( ${TEST_COREDUMPS:-0} )) || exit 1
echo '[{"exe":"/usr/bin/Hyprland","uid":958}]'
SH

run_check() {
  TEST_LOG="$test_tmp/calls.log" OMARCHY_HARDWARE_ROOT="$fixture" PATH="$stub_bin:$PATH" \
    bash "$TOOLS/mac-check" >"$test_tmp/out" 2>"$test_tmp/err"
}

fixture_state() {
  find "$fixture" -type f | sort | while IFS= read -r file; do
    printf '%s %s\n' "$(file_sha256 "$file")" "$file"
  done
}

make_fixture
before=$(fixture_state)
: >"$test_tmp/calls.log"
run_check || fail "a healthy Mac passes" "$(cat "$test_tmp/out" "$test_tmp/err")"
for line in \
  "PASS  kernel           running $kver from linux-aurora 7.1.12.aurora2-7" \
  "PASS  kernel-repo      linux-aurora updates from [omarchy]" \
  "PASS  boot-check       running linux-aurora 7.1.12-2-7-ARCH from aurora-packages-3caea46 (lane=rc)" \
  "PASS  displays         2 active: eDP-1 3456x2160@120, USB-1 3440x1440@60" \
  "PASS  sound-cards      AppleJ416HPAI, AppleJ416" \
  "PASS  default-sink     MacBook Pro J416 Speakers (audio_effect.j416-convolver)" \
  "PASS  snapshots        /.snapshots is a btrfs subvolume holding 2 snapshots" \
  "PASS  gpu              renderD128 is the Apple GPU (apple,agx-t6021), driven by asahi" \
  "INFO  display-ports    DP-1 disconnected, HDMI-A-1 disconnected" \
  "PASS  usb-c            USB-C Left Back (attached, host), USB-C Left Front (empty), USB-C Right (empty)" \
  "INFO  usb-devices      YubiKey OTP+FIDO+CCID on USB-C Left Back at 12 Mb/s" \
  "PASS  camera           the camera is /dev/video0" \
  "PASS  sd-reader        mmc0, no card inserted" \
  "PASS  kbd-backlight    apple::kbd_backlight at 128 of 255" \
  "PASS  battery          macsmc-battery: 87%, Discharging, charging stops at 80%" \
  "INFO  touchid          Touch ID can be turned on under Setup > Security > Fingerprint" \
  "INFO  release          asahi-quattro-59ee15f6, Aurora lane rc" \
  "INFO  boot-file        $(file_sha256 "$fixture/boot/efi/EFI/Linux/omarchy_linux-aurora.efi")  /boot/efi/EFI/Linux/omarchy_linux-aurora.efi" \
  "INFO  boot-file        $(file_sha256 "$fixture/boot/efi/m1n1/boot.bin")  /boot/efi/m1n1/boot.bin" \
  "21 passed, 0 failed, 0 warnings, 0 skipped"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "healthy report has: $line" "$(cat "$test_tmp/out")"
done
pass "a healthy Mac passes every check and prints its boot-file hashes"
[[ $(fixture_state) == "$before" ]] || fail "the check changes nothing on the Mac"
pass "the check changes nothing on the Mac"

: >"$test_tmp/calls.log"
if TEST_FAILED_UNITS=$'foo.service loaded failed failed Foo\n' TEST_FAILED_USER_UNITS=$'bar.service loaded failed failed Bar\n' \
  TEST_WIFI_STATE=disconnected TEST_BOOT_CHECK_STATUS=1 TEST_KERNEL_REPO=none run_check; then
  fail "failures make the check exit non-zero" "$(cat "$test_tmp/out")"
fi
for line in \
  "FAIL  units            failed: foo.service, user:bar.service" \
  "FAIL  wifi             wlan0 is disconnected" \
  "FAIL  boot-check       m1n1/boot.bin on the system ESP is not m1n1 as installed" \
  "FAIL  kernel-repo      no configured repository carries linux-aurora"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "failing report has: $line" "$(cat "$test_tmp/out")"
done
pass "failed units, Wi-Fi, boot check and kernel repository are reported as failures"

rm "$fixture/boot/efi/EFI/Linux/omarchy_linux-aurora.efi" "$fixture/boot/efi/limine.conf"
run_check && fail "a Limine Mac without its boot files fails"
grep -Fxq "FAIL  boot-file        no unified kernel image under /boot/efi/EFI/Linux" "$test_tmp/out" || fail "a missing UKI is named" "$(cat "$test_tmp/out")"
grep -Fxq "FAIL  boot-file        /boot/efi/limine.conf is missing on a limine Mac" "$test_tmp/out" || fail "a missing limine.conf is named" "$(cat "$test_tmp/out")"
pass "a Limine Mac without its unified kernel image or limine.conf fails"
make_fixture

if TEST_SYSTEMCTL_DOWN=1 TEST_DUMMY_SINK=1 run_check; then
  fail "an unanswered systemctl and a dummy sink fail"
fi
grep -Fxq "FAIL  units            systemctl cannot list failed units" "$test_tmp/out" || fail "an unanswered systemctl is not a pass" "$(cat "$test_tmp/out")"
grep -Fxq "FAIL  default-sink     the default sink is PipeWire's dummy output" "$test_tmp/out" || fail "a dummy sink is not a pass" "$(cat "$test_tmp/out")"
pass "an unanswered systemctl and PipeWire's dummy sink fail"

TEST_USER_MANAGER_DOWN=1 run_check && fail "a user manager that does not answer fails"
grep -Fxq "FAIL  units            failed: user manager did not answer" "$test_tmp/out" || fail "an unanswered user manager is named" "$(cat "$test_tmp/out")"
pass "a user manager that does not answer fails the units check"

# A kernel that lost a peripheral the device tree describes fails each check, and
# a display that is plugged in but not shown fails too.
make_fixture
rm -rf "$fixture/sys/class/drm/renderD128" "$fixture/sys/class/typec/port2" "$fixture/sys/class/video4linux" \
  "$fixture/sys/class/mmc_host" "$fixture/sys/class/leds" "$fixture/sys/class/power_supply"
printf 'connected\n' >"$fixture/sys/class/drm/card1-DP-1/status"
printf 'failed\n' >"$fixture/run/omarchy-mac/touchid"
# A phone charging from a port and a keyboard with its own backlight are not the Mac's.
mkdir -p "$fixture/sys/class/power_supply/apple_mfi_fastcharge_3-2" "$fixture/sys/class/leds/g15::kbd_backlight/device"
printf 'Battery\n' >"$fixture/sys/class/power_supply/apple_mfi_fastcharge_3-2/type"
printf 'Device\n' >"$fixture/sys/class/power_supply/apple_mfi_fastcharge_3-2/scope"
ln -s ../../../../bus/hid/drivers/hid-lg-g15 "$fixture/sys/class/leds/g15::kbd_backlight/device/driver"
printf '1\n' >"$fixture/sys/class/leds/g15::kbd_backlight/brightness"
printf '2\n' >"$fixture/sys/class/leds/g15::kbd_backlight/max_brightness"
run_check && fail "a Mac that lost its peripherals fails"
for line in \
  "FAIL  gpu              no render node belongs to the Apple GPU, so the desktop renders in software" \
  "FAIL  display-ports    a display is connected to DP-1, but Hyprland shows nothing there" \
  "FAIL  usb-c            the device tree has 3 USB-C connectors, the kernel registered 2 ports: USB-C Left Back (attached, host), USB-C Left Front (empty)" \
  "FAIL  camera           the device tree enables the camera's ISP, but no video device belongs to it" \
  "FAIL  sd-reader        the device tree has an SD card reader, but the kernel registered no MMC host" \
  "FAIL  kbd-backlight    the device tree has a keyboard backlight, but the kernel registered no LED for it" \
  "FAIL  battery          a MacBook whose battery the kernel does not report" \
  "FAIL  touchid          Touch ID did not come up this boot (failed); see journalctl -u omarchy-mac-touchid-activate and journalctl -k"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "a Mac that lost its peripherals reports: $line" "$(cat "$test_tmp/out")"
done
pass "a lost GPU, port, camera, reader, backlight or battery fails, even beside a phone's battery or a keyboard's backlight, and so does a display Hyprland does not show"

# The same display, shown by Hyprland, is reported with the connector it is on;
# a card in the reader and an unlabelled port's device are named too.
make_fixture
printf 'connected\n' >"$fixture/sys/class/drm/card1-DP-1/status"
mkdir -p "$fixture/sys/class/mmc_host/mmc0/mmc0:0001" "$fixture/sys/devices/platform/39b280000.usb/xhci-hcd.3.auto/usb5/5-1"
printf '480\n' >"$fixture/sys/devices/platform/39b280000.usb/xhci-hcd.3.auto/usb5/5-1/speed"
printf '05ac\n' >"$fixture/sys/devices/platform/39b280000.usb/xhci-hcd.3.auto/usb5/5-1/idVendor"
printf '1234\n' >"$fixture/sys/devices/platform/39b280000.usb/xhci-hcd.3.auto/usb5/5-1/idProduct"
ln -s ../../../devices/platform/39b280000.usb/xhci-hcd.3.auto/usb5/5-1 "$fixture/sys/bus/usb/devices/5-1"
mkdir -p "$fixture/sys/class/drm/card2-DSI-1"
printf 'connected\n' >"$fixture/sys/class/drm/card2-DSI-1/status"
TEST_SHOWS_DP=1 run_check || fail "a shown external display passes" "$(cat "$test_tmp/out")"
for line in \
  "INFO  display-ports    DP-1 connected, HDMI-A-1 disconnected" \
  "PASS  sd-reader        mmc0, a card inserted" \
  "INFO  usb-devices      YubiKey OTP+FIDO+CCID on USB-C Left Back at 12 Mb/s, 05ac:1234 on a port the device tree does not name at 480 Mb/s"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "a shown display, a card and an unnamed port report: $line" "$(cat "$test_tmp/out")"
done
pass "a shown external display, an inserted card and a device on an unnamed port are reported, and a Touch Bar is not a port"

# A display Hyprland keeps disabled is noted, not failed.
make_fixture
printf 'connected\n' >"$fixture/sys/class/drm/card1-DP-1/status"
TEST_DISABLED_DP=1 run_check || fail "a display Hyprland keeps disabled passes" "$(cat "$test_tmp/out")"
grep -Fxq "INFO  display-ports    DP-1 connected, HDMI-A-1 disconnected; Hyprland keeps DP-1 disabled or mirrored" "$test_tmp/out" ||
  fail "a display Hyprland keeps disabled is noted" "$(cat "$test_tmp/out")"
pass "a display Hyprland keeps disabled is noted, not failed"

# On the M4 Pro and M4 Max the connectors, controllers and the reader's bus sit at
# the root, reached through the /proc/device-tree link.
make_fixture m4
run_check || true
for line in \
  "PASS  usb-c            USB-C Left Back (attached, host), USB-C Left Front (empty), USB-C Right (empty)" \
  "INFO  usb-devices      YubiKey OTP+FIDO+CCID on USB-C Left Back at 12 Mb/s" \
  "PASS  sd-reader        mmc0, no card inserted"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "a 14-inch M4 Max reports: $line" "$(cat "$test_tmp/out")"
done
rm -rf "$fixture/sys/class/mmc_host"
run_check && fail "a 14-inch M4 Max that lost its SD card reader fails"
grep -Fxq "FAIL  sd-reader        the device tree has an SD card reader, but the kernel registered no MMC host" "$test_tmp/out" ||
  fail "a 14-inch M4 Max's lost reader is named" "$(cat "$test_tmp/out")"
pass "a 14-inch M4 Max names its ports and the device on each, and fails a lost reader"

# Touch ID turned on whose activation never recorded a status fails; a Mac with no
# sensor records none either.
make_fixture
rm "$fixture/run/omarchy-mac/touchid"
mkdir -p "$fixture/etc/omarchy-mac"
: >"$fixture/etc/omarchy-mac/touchid-on"
run_check && fail "Touch ID turned on with no status fails"
grep -Fxq "FAIL  touchid          Touch ID is on, but nothing recorded its status this boot; see journalctl -k for apple_sep" "$test_tmp/out" ||
  fail "Touch ID turned on with no status is named" "$(cat "$test_tmp/out")"
rm "$fixture/etc/omarchy-mac/touchid-on"
run_check || fail "no Touch ID status without Touch ID turned on passes" "$(cat "$test_tmp/out")"
grep -Fxq "INFO  touchid          no Touch ID status: this Mac has no sensor" "$test_tmp/out" ||
  fail "no Touch ID status without Touch ID turned on is noted" "$(cat "$test_tmp/out")"
pass "Touch ID turned on with no status fails, and no status without it is noted"

# A desktop Mac has none of them, and Touch ID says why it is not offered.
make_fixture
rm -rf "$fixture/proc/device-tree/soc/i2c@39b040000" "$fixture/proc/device-tree/isp@22a000000" "$fixture/proc/device-tree/soc/pcie@590000000" \
  "$fixture/proc/device-tree/led-controller" "$fixture/sys/class/typec" "$fixture/sys/class/video4linux" \
  "$fixture/sys/class/mmc_host" "$fixture/sys/class/leds" "$fixture/sys/class/power_supply" \
  "$fixture/sys/class/drm/card0-eDP-1" "$fixture/sys/class/drm/card1-DP-1" "$fixture/sys/bus/usb/devices/3-1"
printf 'Apple Mac mini (M2 Pro, 2023)\0' >"$fixture/proc/device-tree/model"
printf 'desktop\0' >"$fixture/proc/device-tree/chassis-type"
mkdir -p "$fixture/sys/class/power_supply/hid-a4:83:e7:12:34:56-battery-0"
printf 'Battery\n' >"$fixture/sys/class/power_supply/hid-a4:83:e7:12:34:56-battery-0/type"
printf 'Device\n' >"$fixture/sys/class/power_supply/hid-a4:83:e7:12:34:56-battery-0/scope"
printf 'unsupported:board\n' >"$fixture/run/omarchy-mac/touchid"
run_check || fail "a desktop Mac without these peripherals passes" "$(cat "$test_tmp/out")"
for line in \
  "INFO  display-ports    HDMI-A-1 disconnected" \
  "SKIP  usb-c            this Mac has no USB-C connector in its device tree" \
  "INFO  usb-devices      nothing attached" \
  "SKIP  camera           the device tree leaves the camera off on this Mac" \
  "SKIP  sd-reader        this Mac has no SD card reader" \
  "SKIP  kbd-backlight    this Mac has no keyboard backlight" \
  "SKIP  battery          no battery on this Mac" \
  "INFO  touchid          Touch ID is not offered on this Mac (board)"; do
  grep -Fxq -- "$line" "$test_tmp/out" || fail "a desktop Mac reports: $line" "$(cat "$test_tmp/out")"
done
pass "a desktop Mac skips the ports and peripherals it does not have, a mouse's battery included"
rm -rf "$fixture/sys/class/drm/card1-HDMI-A-1"
run_check && fail "a desktop Mac whose display driver registered no connector fails"
grep -Fxq "FAIL  display-ports    the display driver registered no connector" "$test_tmp/out" ||
  fail "a desktop Mac without a display connector is named" "$(cat "$test_tmp/out")"
pass "a desktop Mac whose display driver registered no connector fails"
make_fixture

rm "$fixture/run/user/$uid/bus"
run_check || fail "no user manager is not a failure" "$(cat "$test_tmp/out")"
grep -Fxq "PASS  units            no failed system units; no user manager to ask about user units" "$test_tmp/out" || fail "the units check says it could not ask the user manager" "$(cat "$test_tmp/out")"
pass "the units check says when it could not ask the user manager"
make_fixture

if TEST_KVER=7.1.13-1-ARCH run_check; then
  fail "a pending reboot fails the kernel check"
fi
grep -Fq "FAIL  kernel           running 7.1.13-1-ARCH does not belong to an installed kernel package" "$test_tmp/out" ||
  fail "the kernel check names the running kernel" "$(cat "$test_tmp/out")"
pass "a kernel that is not the installed package fails"

printf 'format=1\nlane=edge\nreboot_pending=abc:7.1.13-1-ARCH\n' >"$fixture/var/lib/omarchy/apple-silicon-aurora-lane"
: >"$test_tmp/calls.log"
run_check || fail "an open switch journal is not a failure" "$(cat "$test_tmp/out")"
grep -Fq "SKIP  boot-check       a kernel switch journal is open" "$test_tmp/out" || fail "an open journal skips the boot check"
! grep -q boot-check "$test_tmp/calls.log" || fail "the boot check does not run while a switch journal is open"
pass "an open kernel switch journal keeps the boot check from running"
make_fixture

: >"$test_tmp/calls.log"
TEST_SUDO=0 run_check || fail "no sudo is not a failure" "$(cat "$test_tmp/out")"
for id in boot-check boot-file snapshots; do
  grep -Eq "^SKIP  $id " "$test_tmp/out" || fail "without sudo $id is skipped" "$(cat "$test_tmp/out")"
done
! grep -q boot-check "$test_tmp/calls.log" || fail "the boot check does not run without sudo"
pass "root checks are skipped without passwordless sudo"

rm -rf "$fixture/run/user/$uid"
run_check || fail "no session is not a failure" "$(cat "$test_tmp/out")"
grep -Fxq "SKIP  displays         no Hyprland session; log in at the greeter first" "$test_tmp/out" || fail "no session skips displays"
grep -Fxq "SKIP  default-sink     no PipeWire session; log in at the greeter first" "$test_tmp/out" || fail "no session skips the default sink"
pass "session checks are skipped until someone logs in"
make_fixture

# update-m1n1 globs device trees in the locale of the transaction, so the
# boot check must see the caller's locale, not the C locale mac-check parses in.
: >"$test_tmp/calls.log"
(unset LC_ALL; LANG=en_US.UTF-8 run_check) || fail "the boot check runs under the caller's LANG" "$(cat "$test_tmp/out")"
grep -Fxq "boot-check locale: LC_ALL=unset LANG=en_US.UTF-8" "$test_tmp/calls.log" ||
  fail "the boot check sees the caller's LANG without a forced LC_ALL" "$(cat "$test_tmp/calls.log")"
: >"$test_tmp/calls.log"
LC_ALL=de_DE.UTF-8 run_check || fail "the boot check runs under the caller's LC_ALL" "$(cat "$test_tmp/out")"
grep -Fq "boot-check locale: LC_ALL=de_DE.UTF-8 " "$test_tmp/calls.log" ||
  fail "the boot check sees the caller's LC_ALL" "$(cat "$test_tmp/calls.log")"
pass "the boot check runs in the caller's locale, not the C locale"

TEST_COREDUMPS=1 run_check || fail "coredumps are not a failure" "$(cat "$test_tmp/out")"
grep -Fq "INFO  coredumps        this boot: Hyprland (uid 958)" "$test_tmp/out" || fail "coredumps are listed" "$(cat "$test_tmp/out")"
pass "this boot's coredumps are listed for comparison"

printf 'qcom,x1e80100\0' >"$fixture/proc/device-tree/compatible"
status=0
run_check || status=$?
(( status == 2 )) || fail "a non-Apple machine exits 2" "status $status"
grep -Fq "not an Apple Silicon Mac" "$test_tmp/err" || fail "a non-Apple machine says why"
pass "a non-Apple machine is refused"
