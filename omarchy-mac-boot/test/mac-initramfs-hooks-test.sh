#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-mac-initramfs-hooks resolves HOOKS as mkinitcpio -P does for the
# kernel's default preset (omarchy-mx-mac #248).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
config_dir="$tmp/config files"
systemd="$config_dir/systemd.conf"
busybox="$config_dir/busybox-encrypt.conf"
mkdir -p "$tmp/conf.d" "$tmp/presets" "$tmp/bin" "$config_dir"
cp "$ROOT/test/fixtures/mkinitcpio/systemd.conf" "$systemd"
cp "$ROOT/test/fixtures/mkinitcpio/busybox-encrypt.conf" "$busybox"
# Presets contain Bash assignments and arrays. Exercise quoted paths even
# when the checkout itself has no spaces.
printf -v quoted_systemd '%q' "$systemd"
printf -v quoted_busybox '%q' "$busybox"
export OMARCHY_MKINITCPIO_CONF_DIR="$tmp/conf.d" OMARCHY_MKINITCPIO_PRESET_DIR="$tmp/presets"

hooks() {
  OMARCHY_MKINITCPIO_CONF="${CONF:-$busybox}" OMARCHY_MKINITCPIO_KERNEL="${KERNEL:-linux-asahi}" \
    "$ROOT/bin/omarchy-mac-initramfs-hooks"
}
preset() { printf 'PRESETS=(default)\n%s\n' "$@" >"$tmp/presets/linux-asahi.preset"; }

[[ $(hooks) == "base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck" ]] ||
  fail "mkinitcpio.conf alone gives its HOOKS"
printf 'HOOKS=(base systemd block sd-encrypt filesystems)\n' >"$tmp/conf.d/91-test.conf"
printf 'HOOKS+=(fsck)\n' >"$tmp/conf.d/100-local.conf"
[[ $(hooks) == "base systemd block sd-encrypt filesystems fsck" ]] || fail "drop-ins join in version order" "$(hooks)"
rm "$tmp/conf.d"/*.conf
pass "mkinitcpio.conf is joined by its drop-ins in version order"

preset "default_config=$quoted_systemd"
[[ " $(hooks) " == *" systemd "* ]] || fail "a preset default_config decides"
preset "default_config=$quoted_busybox" "default_options=(-c $quoted_systemd)"
[[ " $(hooks) " == *" systemd "* ]] || fail "a -c in default_options wins over default_config"
preset 'default_options="-A systemd"'
[[ $(CONF=$busybox hooks) == *" fsck systemd" ]] || fail "-A appends hooks"
preset "default_config=$quoted_systemd" "default_options=(--skiphooks=systemd,sd-encrypt -A encrypt)"
[[ $(hooks) == "base asahi autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck encrypt" ]] ||
  fail "-S drops and -A appends hooks" "$(hooks)"
printf 'HOOKS="base systemd block sd-encrypt filesystems"\n' >"$tmp/scalar.conf"
preset "default_config=$(printf '%q' "$tmp/scalar.conf")" "default_options=(-vS systemd,sd-encrypt -Audev,encrypt)"
[[ $(hooks) == "base block filesystems udev encrypt" ]] || fail "a scalar HOOKS and bundled -vS resolve as mkinitcpio does" "$(hooks)"
preset "default_config=$quoted_systemd" "default_options=(-S autodetect -- -S systemd)"
[[ $(hooks) == "base systemd asahi microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck" ]] ||
  fail "-- ends the options, as parseopts does" "$(hooks)"
preset 'default_options="--skip systemd"'
[[ " $(CONF=$systemd hooks) " != *" systemd "* ]] || fail "a unique long prefix (--skip) is --skiphooks"
for options in "(-c $quoted_busybox)" "(-c$quoted_busybox)" "(--config=$quoted_busybox)" "(--conf $quoted_busybox)"; do
  preset "default_config=$quoted_systemd" "default_options=$options"
  [[ $(hooks) == "base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck" ]] ||
    fail "default_options=$options selects the busybox configuration" "$(hooks)"
done
# Scalar options are word-split, so use a relative name without spaces for
# that spelling; arrays above keep a path containing spaces as one argument.
preset "default_config=$quoted_systemd" 'default_options="-c ./busybox-encrypt.conf"'
[[ $(cd "$config_dir" && hooks) == "base asahi udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck" ]] ||
  fail "scalar default_options selects the busybox configuration"
pass "the preset's configuration and options decide the hooks as mkinitcpio parses them"

preset 'default_options="-x"'
if hooks >/dev/null; then fail "an option mkinitcpio does not know leaves the hooks unknown"; fi
rm "$tmp/presets/linux-asahi.preset"
if CONF="$tmp/missing.conf" hooks >/dev/null; then fail "an unreadable configuration is unknown"; fi
printf 'MODULES=()\n' >"$tmp/nohooks.conf"
if CONF="$tmp/nohooks.conf" hooks >/dev/null; then fail "a configuration without HOOKS is unknown"; fi
pass "an unknown option, an unreadable configuration or no HOOKS exit 1"

cat >"$tmp/bin/pacman" <<'SH'
#!/bin/bash
[[ $* == "-Qq" ]] && printf 'linux-aurora\n'
SH
chmod +x "$tmp/bin/pacman"
printf 'PRESETS=(default)\ndefault_config=%q\n' "$systemd" >"$tmp/presets/linux-aurora.preset"
[[ " $(PATH="$tmp/bin:$ROOT/bin:$PATH" OMARCHY_MKINITCPIO_CONF=$busybox "$ROOT/bin/omarchy-mac-initramfs-hooks") " == *" systemd "* ]] ||
  fail "the installed kernel's preset is read"
pass "the preset follows the installed Apple Silicon kernel"
