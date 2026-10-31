#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixture=$work/fixture
export OMARCHY_MAC_TOUCHID_TREE=$fixture/tree
export OMARCHY_MAC_TOUCHID_FIRMWARE=$fixture/firmware
export OMARCHY_MAC_TOUCHID_EXTRACTORS=$fixture/extractors
export OMARCHY_MAC_TOUCHID_AGREED=$fixture/etc/touchid-on
export OMARCHY_MAC_TOUCHID_SDDM_AGREED=$fixture/etc/touchid-sddm
export OMARCHY_MAC_TOUCHID_OPTIONS=$fixture/etc/modprobe.conf
export OMARCHY_MAC_TOUCHID_MODULE=$fixture/module
export OMARCHY_MAC_TOUCHID_STATUS=$fixture/run/touchid
export OMARCHY_MAC_TOUCHID_HELPERS=$ROOT/lib
export OMARCHY_MAC_TOUCHID_NODE=$fixture/sep-bio
export OMARCHY_MAC_TOUCHID_KEYBAG=$fixture/keybag
export OMARCHY_MAC_TOUCHID_ESP=$fixture/esp
export OMARCHY_MAC_TOUCHID_CONTAINER=$fixture/container
export OMARCHY_MAC_TOUCHID_PAM=$fixture/pam
export OMARCHY_MAC_TOUCHID_PYTHON=$fixture/bin/python
export OMARCHY_MAC_TOUCHID_LOCK_WAIT=0
export PATH=$fixture/bin:$PATH
mkdir -p "$fixture/bin" "$fixture/extractors"
printf '#!/bin/bash\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
for command in modprobe systemctl python; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >>"%s"\n' "$command" "$fixture/calls" >"$fixture/bin/$command"
done
# A missing input must not reach extraction, waiting, or any live service.
for command in "$fixture/extractors/extract-mesa-calibration" "$fixture/bin/sleep"; do
  printf '#!/bin/bash\necho unexpected >>"%s"\nexit 1\n' "$fixture/calls" >"$command"
done
chmod +x "$fixture/bin/"* "$fixture/extractors/"*

machine() {
  rm -rf "$fixture/tree" "$fixture/firmware" "$fixture/etc" "$fixture/run"
  mkdir -p "$OMARCHY_MAC_TOUCHID_TREE/soc/spi/fingerprint@0" "$OMARCHY_MAC_TOUCHID_TREE/chosen" \
    "$fixture/firmware/apple" "$fixture/firmware/vendor/apple" "$fixture/firmware/updates/apple" "$fixture/run"
  printf '%s\0' "${1:-apple,j715}" "${2:-apple,t8132}" >"$OMARCHY_MAC_TOUCHID_TREE/compatible"
  printf 'apple,mesa-fingerprint\0' >"$OMARCHY_MAC_TOUCHID_TREE/soc/spi/fingerprint@0/compatible"
  printf uuid >"$OMARCHY_MAC_TOUCHID_TREE/chosen/apfs-preboot-uuid"
  truncate -s 10848 "$fixture/firmware/apple/msrk-j715.bin"
  touch "$fixture/sep-bio" "$fixture/keybag"
  printf 'ready\n' >"$fixture/run/touchid"
  : >"$fixture/calls"
}

failures=0
rejected() {
  local name=$1 expected=${2:-unsupported:invalid-calibration} eligibility result=0 consent=no options=no loaded=no
  eligibility=$("$ROOT/lib/touchid-eligibility")
  "$ROOT/lib/touchid-enable" >"$fixture/output" 2>&1 || result=$?
  [[ ! -e $OMARCHY_MAC_TOUCHID_AGREED ]] || consent=yes
  [[ ! -e $OMARCHY_MAC_TOUCHID_OPTIONS ]] || options=yes
  [[ ! -e $fixture/run/touchid-loaded ]] || loaded=yes
  if [[ $eligibility == "$expected" && $result != 0 &&
    $consent == no && $options == no && $loaded == no && ! -s $fixture/calls ]]; then
    pass "$name blocks eligibility, consent, options and loading"
  else
    printf 'not ok - %s: eligibility=%s enable_rc=%s consent=%s options=%s loaded=%s\n' \
      "$name" "$eligibility" "$result" "$consent" "$options" "$loaded" >&2
    failures=$((failures + 1))
  fi
}

# The native evidence qualifies one 130427-byte body, not an FSC2 magic string.
# Synthetic bodies test only the size gate, never identity or authenticity.
for directory in "$fixture/firmware" "$fixture/firmware/vendor" "$fixture/firmware/updates"; do
  for size in 0 4 122131 130426 130428; do
    machine
    truncate -s "$size" "$directory/apple/mesa_calibration.bin"
    rejected "${directory#"$fixture/firmware"}/$size-byte calibration"
  done
  machine
  truncate -s 130427 "$directory/apple/mesa_calibration.bin"
  [[ $("$ROOT/lib/touchid-eligibility") == "available" && ! -s $fixture/calls ]] ||
    fail 'the qualified body size is eligible without writes'
  "$ROOT/lib/touchid-enable" >"$fixture/output" 2>&1 ||
    fail 'a size-qualified J715 reaches the stubbed activation' "$(<"$fixture/output")"
  [[ -f $OMARCHY_MAC_TOUCHID_AGREED && -f $OMARCHY_MAC_TOUCHID_OPTIONS && -f $fixture/run/touchid-loaded ]] &&
    grep -Fxq 'modprobe apple-sep' "$fixture/calls" ||
    fail 'a size-qualified J715 records consent and reaches the stubbed load'
  pass "${directory#"$fixture/firmware"} qualified-size body reaches activation"
done

# No valid copy may mask a bad copy in another firmware lookup directory.
for invalid in "$fixture/firmware" "$fixture/firmware/vendor" "$fixture/firmware/updates"; do
  machine
  for directory in "$fixture/firmware" "$fixture/firmware/vendor" "$fixture/firmware/updates"; do
    truncate -s 130427 "$directory/apple/mesa_calibration.bin"
  done
  truncate -s 0 "$invalid/apple/mesa_calibration.bin"
  rejected "shadowed ${invalid#"$fixture/firmware"}/empty calibration"
done

machine
rejected 'missing calibration' unsupported:no-calibration
for invalid in directory dangling-link; do
  machine
  truncate -s 130427 "$fixture/firmware/vendor/apple/mesa_calibration.bin"
  if [[ $invalid == "directory" ]]; then
    mkdir "$fixture/firmware/updates/apple/mesa_calibration.bin"
  else
    ln -s missing "$fixture/firmware/updates/apple/mesa_calibration.bin"
  fi
  rejected "$invalid shadowing a qualified-size calibration"
done
machine
truncate -s 130427 "$fixture/firmware/vendor/apple/private-fsc2.bin"
ln -s private-fsc2.bin "$fixture/firmware/vendor/apple/mesa_calibration.bin"
[[ $("$ROOT/lib/touchid-eligibility") == "available" ]] || fail 'a readable firmware symlink remains eligible'
pass 'a readable firmware symlink remains eligible'
machine
printf 'apple/private-fsc2.bin\0' >"$OMARCHY_MAC_TOUCHID_TREE/soc/spi/fingerprint@0/firmware-name"
truncate -s 130427 "$fixture/firmware/apple/mesa_calibration.bin"
truncate -s 4 "$fixture/firmware/vendor/apple/private-fsc2.bin"
rejected 'truncated device-tree firmware-name'
truncate -s 130427 "$fixture/firmware/vendor/apple/private-fsc2.bin"
[[ $("$ROOT/lib/touchid-eligibility") == "available" ]] || fail 'device-tree firmware-name is honored'
pass 'device-tree firmware-name selects the calibration'

for board in 'apple,j414c apple,t6021' 'apple,j700 apple,t8140'; do
  read -r model chip <<<"$board"
  machine "$model" "$chip"
  printf legacy >"$fixture/firmware/apple/mesa_calibration.bin"
  truncate -s 1 "$fixture/firmware/apple/msrk-j700.bin"
  [[ $("$ROOT/lib/touchid-eligibility") == "available" ]] || fail 'other boards keep their calibration rules'
done
pass 'other boards keep their calibration rules'
(( failures == 0 )) || fail "$failures calibration regressions"
