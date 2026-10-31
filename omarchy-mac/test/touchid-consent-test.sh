#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Nothing loads the Secure Enclave driver until the owner agrees. Before that,
# the boot-time status says whether Touch ID can be set up; the fingerprint
# setup's enable-fingerprint asks, then touchid-enable turns it on.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
for name in status load; do
  [[ -f $units/omarchy-mac-touchid-$name.service && -L $units/multi-user.target.wants/omarchy-mac-touchid-$name.service &&
    $(readlink "$units/multi-user.target.wants/omarchy-mac-touchid-$name.service") == "../omarchy-mac-touchid-$name.service" ]] ||
    fail "the $name unit is staged and pulled in at boot without enabling"
done
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/touchid-status' "$units/omarchy-mac-touchid-status.service" &&
  grep -Fxq 'Before=display-manager.service fprintd.service' "$units/omarchy-mac-touchid-status.service" ||
  fail 'the status is recorded before the greeter or fprintd look for a reader'
load=$units/omarchy-mac-touchid-load.service
grep -Fxq 'ConditionPathExists=/etc/omarchy-mac/touchid-on' "$load" && grep -Fxq 'ExecStart=/usr/bin/modprobe apple-sep' "$load" &&
  grep -Fxq 'ExecStartPre=/usr/bin/udevadm wait --timeout=20 /dev/disk/by-partlabel/iBootSystemContainer' "$load" ||
  fail "the driver loads at boot only on the owner's record, after the iBoot System Container's link it opens"
! grep -Eq '^(Wants|Requires|BindsTo|After)=.*\.device' "$load" ||
  fail "the load waits for the link only once its condition holds: a device dependency holds up every boot"
for name in enable-fingerprint disable-fingerprint; do
  [[ -x $work/root/usr/lib/omarchy/mac/$name ]] || fail "the $name entrypoint is staged for omarchy-lifecycle-dispatch"
done
[[ ! -e $work/root/etc/omarchy-mac/touchid-on ]] && ! grep -rqs 'apple-sep' "$work/root/etc" "$work/root/usr/lib/modules-load.d" ||
  fail 'the package itself never turns Touch ID on'
pass 'the status and load units and the enable and disable entrypoints are staged, and nothing turns Touch ID on'

fixture=$work/fixture
tree=$fixture/tree
export OMARCHY_MAC_TOUCHID_PAM=$fixture/pam
mkdir -p "$fixture/bin" "$fixture/extractors"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
# The stub keeps the driver options it was loaded with, as modprobe reads them.
# With no-node or no-keybag, the driver loads but that never appears.
printf '#!/bin/sh\necho modprobe "$@" >>"%s"\ncp "%s" "%s" 2>/dev/null\n[ -e "%s" ] && exit 1\nmkdir -p "%s"\n[ -e "%s" ] || touch "%s"\n[ -e "%s" ] || touch "%s"\n' \
  "$fixture/calls" "$fixture/etc/modprobe.conf" "$fixture/options-at-load" "$fixture/modprobe-fails" \
  "$fixture/module" "$fixture/no-node" "$fixture/sep-bio" "$fixture/no-keybag" "$fixture/keybag" >"$fixture/bin/modprobe"
printf '#!/bin/sh\necho systemctl "$@" >>"%s"\n[ "$1" = start ] && printf "%%s\\n" "$(cat "%s")" >"%s"\nexit 0\n' \
  "$fixture/calls" "$fixture/activation" "$fixture/run/touchid" >"$fixture/bin/systemctl"
printf '#!/bin/sh\n[ -e "%s" ] || echo /usr/lib/omarchy/mac/enable-fingerprint\n' "$fixture/no-hook" >"$fixture/bin/omarchy-lifecycle-dispatch"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sleep"
printf '#!/bin/sh\necho calibration >>"%s"\nprintf calibration >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-mesa-calibration"
chmod +x "$fixture/bin/"* "$fixture/extractors/"*

# A Neo's factory records as asahi-installer leaves them on the ESP, an iBoot
# System Container holding them (and one that doesn't), and the key they make,
# built here independently of touchid-root-key.
mkdir -p "$work/factory"
cat >"$work/factory.py" <<'PY'
import hashlib, io, os, sys, tarfile
def der(tag, value):
    n = len(value)
    head = bytes([n]) if n < 0x80 else (lambda size: bytes([0x80 | len(size)]) + size)(n.to_bytes((n.bit_length() + 7) // 8, "big"))
    return bytes([tag]) + head + value
out = sys.argv[1]
im4p = der(0x30, der(0x16, b"IM4P") + der(0x16, b"MSRk") + der(0x16, b"1") + der(0x04, b"k" * 1500))
msrk = der(0x30, der(0x16, b"IMG4") + im4p + der(0xA0, der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x01") + b"\x31\x00")))
seal = der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x00") + der(0x04, b"s" * 900))
other_seal = der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x00") + der(0x04, b"o" * 900))
trust = b"T" * 3191
named = "trustobject-" + hashlib.sha256(trust).hexdigest().upper()
def archive(name, records, extra=()):
    """records go in com.apple.factorydata; extra are (path, data, None) for
    a file or (path, None, (TarInfo type, link target)) anywhere."""
    with tarfile.open(os.path.join(out, name), "w:gz") as tar:
        entries = [("firmware/other.bin", b"abcd", None)] + [("com.apple.factorydata/" + n, d, None) for n, d in records]
        for member, data, target in entries + list(extra):
            info = tarfile.TarInfo(member)
            if data is None:
                info.type, info.linkname = target
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
records = [("MSRk-00003356-AA", msrk), ("seal-00008140-001E", seal), (named, trust), ("trustobject-current", trust)]
archive("all_firmware.tar.gz", records)
archive("two-seals.tar.gz", records + [("seal-00008140-002F", other_seal)])
archive("other-chip.tar.gz", [("MSRk-00003356-AA", msrk), ("seal-00008122-001E", seal), (named, trust), ("trustobject-current", trust)])
# The trust bundle: a trustobject-current whose named bundle holds other bytes,
# and, without trustobject-current, one bundle whose bytes don't match its name.
archive("current-differs.tar.gz", records[:2] + [(named, b"U" * 3191), ("trustobject-current", trust)])
archive("misnamed-trust.tar.gz", records[:2] + [("trustobject-" + hashlib.sha256(b"U").hexdigest().upper(), trust)])
# An MSRk record whose payload isn't an MSRk.
other_im4p = der(0x30, der(0x16, b"IM4P") + der(0x16, b"FSC2") + der(0x16, b"1") + der(0x04, b"k" * 1500))
other_msrk = der(0x30, der(0x16, b"IMG4") + other_im4p + der(0xA0, der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x01") + b"\x31\x00")))
archive("wrong-payload.tar.gz", [("MSRk-00003356-AA", other_msrk)] + records[1:])
archive("duplicate.tar.gz", records + [("seal-00008140-001E", seal)])
archive("linked-seal.tar.gz", [records[0], records[2], records[3]],
        [("com.apple.factorydata/seal-00008140-001E", None, (tarfile.SYMTYPE, "/etc/passwd"))])
archive("oversized.tar.gz", records + [("trustobject-" + "0" * 64, b"\0" * ((16 << 20) + 1))])
# The archive's bounds: 16384 entries in all, and 32 MiB of records kept.
filler_entries = lambda n: [("firmware/filler-%d" % i, b"", None) for i in range(n)]
archive("at-entry-limit.tar.gz", records, filler_entries((1 << 14) - 1 - len(records)))
archive("many-entries.tar.gz", records, filler_entries((1 << 14) - len(records)))
archive("retained.tar.gz", records + [("trustobject-" + c * 64, b"\0" * (12 << 20)) for c in "ABC"])
# A seal outside com.apple.factorydata is no record, and a later macOS's
# subdirectory or link in the cache is skipped.
archive("decoy.tar.gz", records, [("firmware/com.apple.factorydata.old/seal-00008140-DECOY", other_seal, None),
                                  ("seal-00008140-DECOY", other_seal, None),
                                  ("elsewhere/com.apple.factorydata/seal-00008140-DECOY", other_seal, None)])
archive("unrelated.tar.gz", records, [("com.apple.factorydata/subdir", None, (tarfile.DIRTYPE, "")),
                                      ("com.apple.factorydata/subdir/seal-00008140-NESTED", other_seal, None),
                                      ("com.apple.factorydata/latest", None, (tarfile.SYMTYPE, "MSRk-00003356-AA")),
                                      ("com.apple.factorydata/Info.plist", b"<plist/>", None)])
filler = lambda n: bytes((i * 7) & 0xFF for i in range(n))
with open(os.path.join(out, "isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + msrk + filler(9 << 20) + seal + filler(4096) + trust + filler(1 << 20))
with open(os.path.join(out, "other-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + msrk + trust + filler(1 << 20))
with open(os.path.join(out, "wrong-payload-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + other_msrk + seal + trust + filler(1 << 20))
with open(os.path.join(out, "no-trust-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + msrk + seal + filler(1 << 20))
with open(os.path.join(out, "no-msrk-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + seal + trust + filler(1 << 20))
# The seal straddles the scan's first 8 MiB read.
with open(os.path.join(out, "boundary-isc.img"), "wb") as fd:
    fd.write(filler((8 << 20) - 400) + seal + filler(4096) + msrk + trust + filler(1 << 20))
image = der(0x30, der(0x16, b"IMG4") + im4p + der(0xA0, seal))
with open(os.path.join(out, "key.bin"), "wb") as fd:
    fd.write(der(0x30, der(0x16, b"comb") + der(0x30, der(0x16, b"fdrd") + der(0x04, image))
                       + der(0x30, der(0x16, b"secb") + der(0x04, trust))))
with open(os.path.join(out, "j715-msrk.bin"), "wb") as fd:
    fd.write(bytes(index % 251 for index in range(10848)))
PY
python3 -I "$work/factory.py" "$work/factory"
# Any copy of the sensor key under the fixture other than the one named.
key_copies() {
  find "$fixture" -name 'msrk-j700.bin*' ! -path "${1:-/nonexistent}"
}

# A device tree: the machine's compatible list, a sensor node, and the identity.
machine() {
  rm -rf "$tree" "$fixture/firmware" "$fixture/run" "$fixture/etc" "$fixture/sep-bio" "$fixture/keybag" "$fixture/calls" "$fixture/no-hook" "$fixture/no-node" "$fixture/no-keybag" "$fixture/options-at-load" "$fixture/module" \
    "$fixture/esp"
  mkdir -p "$tree/soc/spi@39b108000/fingerprint@0" "$tree/chosen" "$fixture/firmware" "$fixture/run"
  printf '%s\0' "$@" >"$tree/compatible"
  printf 'apple,mesa-fingerprint\0' >"$tree/soc/spi@39b108000/fingerprint@0/compatible"
  printf 'okay\0' >"$tree/soc/spi@39b108000/fingerprint@0/status"
  printf 'uuid' >"$tree/chosen/apfs-preboot-uuid"
  touch "$fixture/calls"
}
neo() {
  machine apple,j700 apple,t8140 apple,arm-platform
  printf 'apple/mesacal-j700.bin\0' >"$tree/soc/spi@39b108000/fingerprint@0/firmware-name"
  mkdir -p "$fixture/firmware/vendor/apple" "$fixture/esp/asahi"
  printf sealed >"$fixture/firmware/vendor/apple/mesacal-j700.bin"
  cp "$work/factory/all_firmware.tar.gz" "$fixture/esp/asahi/"
}
run() {
  PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_TREE=$tree OMARCHY_MAC_TOUCHID_FIRMWARE=$fixture/firmware \
    OMARCHY_MAC_TOUCHID_EXTRACTORS=$fixture/extractors OMARCHY_MAC_TOUCHID_AGREED=$fixture/etc/touchid-on \
    OMARCHY_MAC_TOUCHID_OPTIONS=$fixture/etc/modprobe.conf OMARCHY_MAC_TOUCHID_MODULE=$fixture/module \
    OMARCHY_MAC_TOUCHID_STATUS=$fixture/run/touchid OMARCHY_MAC_TOUCHID_HELPERS=$ROOT/lib \
    OMARCHY_MAC_TOUCHID_NODE=$fixture/sep-bio OMARCHY_MAC_TOUCHID_KEYBAG=$fixture/keybag \
    OMARCHY_MAC_TOUCHID_PAM=$fixture/pam OMARCHY_MAC_TOUCHID_SDDM_AGREED=$fixture/etc/touchid-sddm \
    OMARCHY_MAC_TOUCHID_ESP=$fixture/esp OMARCHY_MAC_TOUCHID_CONTAINER=${container:-$work/factory/isc.img} \
    OMARCHY_MAC_TOUCHID_PYTHON=${python:-python3} "$ROOT/lib/$1" "${@:2}"
}
eligibility() {
  run touchid-eligibility
}

machine apple,j414c apple,t6021 apple,arm-platform
[[ $(eligibility) == "available" ]] || fail 'an M2 Max with a sensor, an identity and an extractor is available' "$(eligibility)"
python=no-such-python
[[ $(eligibility) == "unsupported:no-calibration" ]] || fail 'without Python the extractor cannot run, so nothing is offered'
unset python
rm -rf "$tree/soc"
[[ $(eligibility) == "none" ]] || fail 'a Mac with no sensor node has no Touch ID'
machine apple,j414c apple,t6021 apple,arm-platform
printf 'disabled\0' >"$tree/soc/spi@39b108000/fingerprint@0/status"
[[ $(eligibility) == "none" ]] || fail 'a disabled sensor node is no Touch ID'
machine apple,j314s apple,t6000 apple,arm-platform
[[ $(eligibility) == "unsupported:m1-family" ]] || fail 'M1-family Macs wait for their xART guard path'
machine apple,j504 apple,t8122 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'a T8122 board whose wiring the driver has not read is unsupported'
machine apple,j613 apple,t8122 apple,arm-platform
[[ $(eligibility) == "available" ]] || fail 'the M3 Air J613 is available'
rm "$tree/chosen/apfs-preboot-uuid"
[[ $(eligibility) == "unsupported:no-os-identity" ]] || fail 'without the forwarded identity there is no lane for Linux'
neo
rm "$fixture/firmware/vendor/apple/mesacal-j700.bin"
[[ $(eligibility) == "unsupported:no-calibration" ]] ||
  fail "the Neo's calibration must be the sealed one its installer wrote, never a fresh carve"
neo
[[ $(eligibility) == "available" ]] || fail "a Neo with its installer's calibration and its factory records on the ESP is available"
python=no-such-python
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail "a Neo without Python can't rebuild its sensor key"
unset python
rm "$fixture/esp/asahi/all_firmware.tar.gz"
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail "a Neo without its factory records on the ESP can't rebuild its sensor key"
mkdir -p "$fixture/firmware/updates/apple"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
[[ $(eligibility) == "available" ]] || fail "a Neo whose sensor key is installed needs nothing else"
pass 'only a Mac whose setup can finish is available'

# The J715 has no supported automatic FSC2/MSRk extractor. Neither another M4
# board nor the Neo's key qualifies it, and checking eligibility writes nothing.
machine apple,j713 apple,t8132 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'an unqualified M4 board stays unsupported'
machine apple,j715 apple,t8132 apple,arm-platform
[[ $(eligibility) == "unsupported:no-calibration" ]] || fail 'J715 never substitutes the container calibration'
mkdir -p "$fixture/firmware/vendor/apple"
truncate -s 130427 "$fixture/firmware/vendor/apple/mesa_calibration.bin"
cp "$work/factory/key.bin" "$fixture/firmware/vendor/apple/msrk-j700.bin"
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail "the Neo's key does not qualify J715"
cp "$work/factory/j715-msrk.bin" "$fixture/firmware/vendor/apple/msrk-j715.bin"
[[ $(eligibility) == "available" && ! -s $fixture/calls ]] || fail 'a prepared J715 is available without writes'
echo ready >"$fixture/activation"
out=$(run touchid-enable 2>&1) || fail 'J715 uses its installed FDR key' "$out"
! grep -Fxq calibration "$fixture/calls" || fail 'J715 never carves a replacement calibration'
cmp -s "$fixture/firmware/vendor/apple/msrk-j715.bin" "$work/factory/j715-msrk.bin" ||
  fail 'J715 keeps the supplied key unchanged'
[[ -f $fixture/etc/touchid-on ]] || fail 'J715 records boot-time enablement'
machine apple,j715 apple,t8132 apple,arm-platform
mkdir -p "$fixture/firmware/vendor/apple"
truncate -s 130427 "$fixture/firmware/vendor/apple/mesa_calibration.bin"
printf incomplete >"$fixture/firmware/vendor/apple/msrk-j715.bin"
! out=$(run touchid-enable 2>&1) && [[ ! -s $fixture/calls && ! -e $fixture/etc/touchid-on ]] ||
  fail 'an incomplete J715 key fails before loading or enabling the driver' "$out"
pass 'J715 keeps private factory inputs and refuses missing or incomplete inputs before enabling'

# At boot the status says so for the detector, and never loads the driver.
machine apple,j414c apple,t6021 apple,arm-platform
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && $(stat -c %a "$fixture/run/touchid") == 644 ]] ||
  fail 'an available Mac records available, readable by the session user'
[[ ! -s $fixture/calls ]] || fail 'recording the status loads and carves nothing' "$(<"$fixture/calls")"
touch "$fixture/keybag"
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && ! -s $fixture/calls && ! -e $fixture/etc/touchid-on ]] ||
  fail 'a keybag from an earlier load is not agreement: the owner is asked like anyone else'
touch "$fixture/no-hook"
run touchid-status
[[ $(<"$fixture/run/touchid") == "unsupported:runtime" ]] ||
  fail "an Omarchy that can't ask first is offered nothing, so the one invitation is not spent"
machine apple,j314s apple,t6000 apple,arm-platform
run touchid-status
[[ $(<"$fixture/run/touchid") == "unsupported:m1-family" ]] || fail 'an unsupported Mac records why'
machine apple,j414c apple,t6021 apple,arm-platform
rm -rf "$tree/soc"
run touchid-status
[[ ! -e $fixture/run/touchid ]] || fail 'a Mac with no sensor records nothing'
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
run touchid-status
[[ ! -e $fixture/run/touchid && ! -s $fixture/calls ]] || fail 'once Touch ID is on, the activation records the status'
# Nothing reads a Neo's sensor key before its owner agrees, at boot or after.
for agreed in no yes; do
  neo
  mkdir -p "$fixture/etc"
  [[ $agreed == no ]] || touch "$fixture/etc/touchid-on"
  run touchid-status
  [[ $agreed == yes || $(<"$fixture/run/touchid") == "available" ]] || fail 'a Neo with its factory records on the ESP is available'
  [[ -z $(key_copies) && ! -s $fixture/calls ]] && cmp -s "$fixture/esp/asahi/all_firmware.tar.gz" "$work/factory/all_firmware.tar.gz" ||
    fail "the boot status rebuilds, keeps and loads nothing, and leaves the ESP alone (agreed: $agreed)" "$(key_copies)"
done
pass 'the boot status records available or why not, and never turns Touch ID on'

# Turning it on: carve what is missing, record the agreement, load now, and
# succeed only once the activation says Touch ID can enrol and match.
machine apple,j414c apple,t6021 apple,arm-platform
echo ready >"$fixture/activation"
out=$(run touchid-enable 2>&1) || fail 'an available Mac whose activation reads ready turns on' "$out"
[[ $(<"$fixture/firmware/updates/apple/mesa_calibration.bin") == "calibration" ]] ||
  fail 'the calibration is carved into the updates firmware directory under the default name'
[[ -f $fixture/etc/touchid-on && $(stat -c %a "$fixture/etc/touchid-on") == 644 ]] || fail "the owner's agreement is recorded"
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/options-at-load" &&
  [[ $(stat -c %a "$fixture/etc/modprobe.conf") == 644 ]] ||
  fail "the driver is loaded with the options that let it write, which a read-only default needs"
[[ $(<"$fixture/calls") == $'calibration\nmodprobe apple-sep\nsystemctl start omarchy-mac-touchid-activate.service\nsystemctl try-restart fprintd.service' ]] ||
  fail 'it carves, loads the driver, waits for the activation, then restarts a running fprintd' "$(<"$fixture/calls")"
[[ $out == *"Touch ID is on."* ]] || fail 'it says so' "$out"
# A Neo's sensor key is rebuilt only now, from its factory records on the ESP,
# byte for byte, root-only, and nowhere else.
neo
installed_key=$fixture/firmware/updates/apple/msrk-j700.bin
out=$(run touchid-enable 2>&1) || fail 'a Neo turns on' "$out"
cmp -s "$installed_key" "$work/factory/key.bin" && [[ $(stat -c %a "$installed_key") == 600 && -z $(key_copies "$installed_key") ]] ||
  fail "the Neo's sensor key is rebuilt from its factory records, root-only, with no other copy" "$(key_copies)"
! grep -Fxq calibration "$fixture/calls" || fail "the Neo's sealed calibration is kept, never carved again"
neo
cp "$work/factory/key.bin" "$fixture/firmware/vendor/apple/msrk-j700.bin"
rm "$fixture/esp/asahi/all_firmware.tar.gz"
run touchid-enable >/dev/null 2>&1 && [[ -z $(key_copies "$fixture/firmware/vendor/apple/msrk-j700.bin") ]] ||
  fail 'a Neo with an installed sensor key turns on without rebuilding it'
# Records another Mac's, or swapped on the ESP, or that can't be told apart,
# give no key, and nothing turns on.
for case in other-container two-seals other-chip truncated; do
  neo
  case $case in
    two-seals | other-chip) cp "$work/factory/$case.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz" ;;
    truncated) head -c "$(($(stat -c %s "$work/factory/all_firmware.tar.gz") / 2))" "$work/factory/all_firmware.tar.gz" >"$fixture/esp/asahi/all_firmware.tar.gz" ;;
  esac
  [[ $case == other-container ]] && container=$work/factory/other-isc.img
  ! out=$(run touchid-enable 2>&1) && [[ $out == *"sensor key could not be read"* && -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] &&
    ! grep -q modprobe "$fixture/calls" || fail "a Neo whose factory records are $case gets no key, and nothing turns on" "$out; $(key_copies)"
  unset container
done
grep -q "not all in this Mac's iBoot System Container" <<<"$(container=$work/factory/other-isc.img; neo; run touchid-enable 2>&1)" ||
  fail "records not all in this Mac's iBoot System Container are said to be another Mac's"
for refusal in "current-differs:differs from the named trust bundle" "misnamed-trust:does not match its name" \
  "wrong-payload:not a whole sensor root key" "duplicate:twice" "linked-seal:not a regular file" "oversized:too large" \
  "no-trust:not all in this Mac's" "no-msrk:not all in this Mac's" "many-entries:more than 16384 entries" \
  "retained:too large together"; do
  case=${refusal%%:*}
  neo
  if [[ $case == no-trust || $case == no-msrk ]]; then
    container=$work/factory/$case-isc.img
  else
    cp "$work/factory/$case.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
  fi
  [[ $case == wrong-payload ]] && container=$work/factory/wrong-payload-isc.img
  ! out=$(run touchid-enable 2>&1) && [[ $out == *"sensor key could not be read"* && $out == *"${refusal#*:}"* && -z $(key_copies) ]] ||
    fail "a Neo whose factory records are $case gets no key, and is told why" "$out; $(key_copies)"
  unset container
done
# Only the cache's own MSRk, seal and trust bundle records count; a record
# straddling the scan's 8 MiB reads is still found.
for case in decoy unrelated boundary at-entry-limit; do
  neo
  if [[ $case == boundary ]]; then
    container=$work/factory/boundary-isc.img
  else
    cp "$work/factory/$case.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
  fi
  out=$(run touchid-enable 2>&1) && cmp -s "$installed_key" "$work/factory/key.bin" ||
    fail "a Neo whose factory records are $case still gets its key" "$out"
  unset container
done
# A temporary copy an interrupted run left, readable by anyone, is replaced,
# never written into.
neo
mkdir -p "${installed_key%/*}"
printf stale >"$installed_key.new"
chmod 0644 "$installed_key.new"
# A second name for the stale file shows whether the key was written into it.
ln "$installed_key.new" "$fixture/stale-link"
run touchid-enable >/dev/null 2>&1 && cmp -s "$installed_key" "$work/factory/key.bin" &&
  [[ $(stat -c %a "$installed_key") == 600 && -z $(key_copies "$installed_key") &&
    $(<"$fixture/stale-link") == stale && $(stat -c %a "$fixture/stale-link") == 644 ]] ||
  fail "a stale temporary copy is replaced by a root-only key, never written into" "$(key_copies)"
rm -f "$fixture/stale-link"
# A key that can't take its name leaves no temporary copy.
neo
mkdir -p "$installed_key/in-the-way"
! run touchid-enable >/dev/null 2>&1 && [[ -z $(key_copies "$installed_key") && -d $installed_key/in-the-way ]] ||
  fail "a key that can't be installed leaves nothing behind" "$(key_copies)"
# A yes that fails later takes back the key it rebuilt, with the agreement.
neo
touch "$fixture/modprobe-fails"
! run touchid-enable >/dev/null 2>&1 && [[ -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] ||
  fail "a Touch ID that fails to turn on keeps no sensor key it rebuilt" "$(key_copies)"
rm "$fixture/modprobe-fails"
neo
mkdir -p "${installed_key%/*}"
cp "$work/factory/key.bin" "$installed_key"
touch "$fixture/modprobe-fails"
! run touchid-enable >/dev/null 2>&1 && cmp -s "$installed_key" "$work/factory/key.bin" ||
  fail "a failure leaves a sensor key this run didn't rebuild"
rm "$fixture/modprobe-fails"
# An extractor that fails after its rename (a directory sync, say) leaves no key.
neo
printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done\nprintf key >"$2"\nexit 1\n' >"$fixture/bin/late-failing-python"
chmod +x "$fixture/bin/late-failing-python"
! python=$fixture/bin/late-failing-python run touchid-enable >/dev/null 2>&1 && [[ -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] ||
  fail "a key the extractor installed before failing is taken back" "$(key_copies)"
# A sensor key counts only once it is whole: a broken one in the updates
# directory is rebuilt, and one elsewhere, or one that can't be checked, stops.
neo
mkdir -p "${installed_key%/*}"
printf 'not a key' >"$installed_key"
out=$(run touchid-enable 2>&1) && cmp -s "$installed_key" "$work/factory/key.bin" && [[ $(stat -c %a "$installed_key") == 600 ]] ||
  fail "a broken sensor key in the updates directory is rebuilt, not trusted" "$out"
neo
printf 'not a key' >"$fixture/firmware/vendor/apple/msrk-j700.bin"
! out=$(run touchid-enable 2>&1) && [[ $out == *"msrk-j700.bin is not whole; remove it"* && ! -e $fixture/etc/touchid-on ]] &&
  [[ $(<"$fixture/firmware/vendor/apple/msrk-j700.bin") == "not a key" && -z $(key_copies "$fixture/firmware/vendor/apple/msrk-j700.bin") ]] &&
  ! grep -q modprobe "$fixture/calls" || fail "a broken sensor key outside the updates directory stops the setup and is left alone" "$out"
neo
cp "$work/factory/key.bin" "$fixture/firmware/vendor/apple/msrk-j700.bin"
! out=$(python=no-such-python run touchid-enable 2>&1) && [[ $out == *"can't be checked without Python"* && ! -e $fixture/etc/touchid-on ]] ||
  fail "a sensor key that can't be checked is not trusted" "$out"
# A check that fails to run is no verdict: the key stays, and nothing turns on.
neo
mkdir -p "${installed_key%/*}"
cp "$work/factory/key.bin" "$installed_key"
printf '#!/bin/sh\nexit 1\n' >"$fixture/bin/broken-python"
chmod +x "$fixture/bin/broken-python"
! out=$(python=$fixture/bin/broken-python run touchid-enable 2>&1) && [[ $out == *"could not be checked"* && ! -e $fixture/etc/touchid-on ]] &&
  cmp -s "$installed_key" "$work/factory/key.bin" || fail "a sensor key whose check fails to run is neither trusted nor removed" "$out"
# A broken key in the updates directory that can't be rebuilt goes.
neo
mkdir -p "${installed_key%/*}"
printf 'not a key' >"$installed_key"
rm "$fixture/esp/asahi/all_firmware.tar.gz"
! out=$(run touchid-enable 2>&1) && [[ $out == *"sensor key could not be read"* && -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] ||
  fail "a broken sensor key that can't be rebuilt is removed, and nothing turns on" "$out; $(key_copies)"
# One setup or removal at a time: a run that can't take the lock does nothing,
# and one that waits for it goes on once it is free.
neo
exec {held}>>"$fixture/run/touchid.lock"
flock "$held"
! out=$(OMARCHY_MAC_TOUCHID_LOCK_WAIT=0 run touchid-enable 2>&1) && [[ $out == *"another Touch ID setup or removal is still running"* ]] &&
  [[ -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] && ! grep -q modprobe "$fixture/calls" ||
  fail "a setup that can't take the lock touches nothing" "$out; $(key_copies)"
exec {held}>&-
# The lock is released only once the setup is seen waiting for it.
neo
exec {held}>>"$fixture/run/touchid.lock"
flock "$held"
# The setup gets no copy of the held descriptor, which would keep the lock.
OMARCHY_MAC_TOUCHID_LOCK_WAIT=30 run touchid-enable >"$fixture/out" 2>&1 {held}>&- &
waiter=$!
for ((attempt = 0; attempt < 200; attempt++)); do
  waiting=$(pgrep -f '^flock -w 30 [0-9]+$' || true)
  [[ -n $waiting ]] && break
  sleep 0.05
done
exec {held}>&-
wait "$waiter" && cmp -s "$installed_key" "$work/factory/key.bin" && [[ -n $waiting ]] ||
  fail "a setup that waits for the lock goes on once it is free" "$(<"$fixture/out")"
# A driver whose node never appears: the activation never ran, so the status
# says it failed and the owner is pointed at the kernel log.
machine apple,j414c apple,t6021 apple,arm-platform
touch "$fixture/no-node"
# The activation never runs without the node, so the status stays the boot's.
echo available >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"never appeared"* && $out == *"journalctl -k"* && $out != *"omarchy-mac-touchid-activate"* ]] &&
  [[ $(<"$fixture/run/touchid") == failed && $(stat -c %a "$fixture/run/touchid") == 644 && ! -e $fixture/etc/touchid-on ]] ||
  fail "a node that never appears records failed, takes the agreement back and points at the kernel log" "$out; $(cat "$fixture/run/touchid" 2>&1)"
# An update in the same boot runs the status again: the failure stands until a
# restart, whose fresh /run offers Touch ID again.
run touchid-status
[[ $(<"$fixture/run/touchid") == failed ]] || fail "an update in the same boot keeps the failure" "$(<"$fixture/run/touchid")"
rm -f "$fixture/run/touchid-loaded"
run touchid-status
[[ $(<"$fixture/run/touchid") == available ]] || fail "the next boot offers Touch ID again" "$(<"$fixture/run/touchid")"
# Only a reason a failed bring-up recorded stands: the status's own results, and
# a ready that Touch ID being turned off this boot left, are worked out again.
touch "$fixture/run/touchid-loaded"
for kept in ready unsupported:runtime; do
  echo "$kept" >"$fixture/run/touchid"
  run touchid-status
  [[ $(<"$fixture/run/touchid") == available ]] || fail "a status of $kept from earlier this boot is worked out again" "$(<"$fixture/run/touchid")"
done
rm -f "$fixture/run/touchid-loaded"
rm "$fixture/no-node"
machine apple,j414c apple,t6021 apple,arm-platform
touch "$fixture/no-keybag"
! out=$(run touchid-enable 2>&1) && [[ $out == *"$fixture/keybag never appeared"* && $out == *"journalctl -k"* ]] &&
  [[ $(<"$fixture/run/touchid") == failed ]] ||
  fail "a keybag that never appears records failed and points at the kernel log" "$out"
rm "$fixture/no-keybag"
# The node and keybag appeared but the activation recorded nothing.
machine apple,j414c apple,t6021 apple,arm-platform
echo available >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"the activation recorded nothing"* && $(<"$fixture/run/touchid") == failed ]] ||
  fail "an activation that recorded nothing leaves failed and says so" "$out; $(cat "$fixture/run/touchid" 2>&1)"
machine apple,j414c apple,t6021 apple,arm-platform
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"did not become ready (not-ready)"* && $(<"$fixture/run/touchid") == not-ready ]] &&
  ! grep -q try-restart "$fixture/calls" ||
  fail 'an activation that does not reach ready fails, says what it read, and leaves fprintd alone' "$out"
[[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf && $out == *"restart before trying again"* ]] ||
  fail 'a Touch ID that never became ready takes the agreement back, so it does not load at every boot' "$out"
# A retry in the same boot after an ordinary failure: the driver this script
# loaded is not one loaded without the options.
! out=$(run touchid-enable 2>&1) && [[ -d $fixture/module && ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] ||
  fail 'a retry after a failure in the same boot takes the agreement back again' "$out; $(ls -a "$fixture/etc" "$fixture/run" "$fixture/module" 2>&1 | tr '\n' ' ')"
echo ready >"$fixture/activation"
machine apple,j414c apple,t6021 apple,arm-platform
printf '#!/bin/sh\nexit 1\n' >"$fixture/extractors/extract-mesa-calibration"
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/etc/touchid-on ]] && ! grep -q modprobe "$fixture/calls" ||
  fail 'a calibration that cannot be read turns nothing on'
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
! run touchid-enable >/dev/null 2>&1 && [[ -e $fixture/etc/touchid-on ]] ||
  fail "a failure keeps the record of an owner who agreed earlier"
machine apple,j414c apple,t6021 apple,arm-platform
printf '#!/bin/sh\nprintf partial >"$2"\nexit 1\n' >"$fixture/extractors/extract-mesa-calibration"
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/firmware/updates/apple/mesa_calibration.bin &&
  ! -e $fixture/firmware/updates/apple/mesa_calibration.bin.new ]] ||
  fail 'a calibration read only partly is never installed under its name'
printf '#!/bin/sh\necho calibration >>"%s"\nprintf calibration >"$2"\n' "$fixture/calls" >"$fixture/extractors/extract-mesa-calibration"
run touchid-enable >/dev/null 2>&1 && [[ $(<"$fixture/firmware/updates/apple/mesa_calibration.bin") == "calibration" ]] ||
  fail 'a retry after a partial read carves the calibration again'
# A record or options that can't be written is a Touch ID that isn't on.
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc/touchid-on/in-the-way"
! out=$(run touchid-enable 2>&1) && [[ $out == *"agreement could not be recorded"* ]] && ! grep -q modprobe "$fixture/calls" ||
  fail "an agreement that can't be recorded fails before anything loads" "$out"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc/modprobe.conf/in-the-way"
! out=$(run touchid-enable 2>&1) && [[ $out == *"options could not be written"* && ! -e $fixture/etc/touchid-on ]] &&
  ! grep -q modprobe "$fixture/calls" ||
  fail "options that can't be written fail, take the agreement back and load nothing" "$out"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc/modprobe.conf.new/in-the-way"
touch "$fixture/etc/touchid-on"
printf 'options apple_sep xart_writes=1 provision_keybag=1\n' >"$fixture/etc/modprobe.conf"
! run touchid-enable >/dev/null 2>&1 && grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" &&
  [[ -e $fixture/etc/touchid-on ]] ||
  fail "a write that fails leaves an earlier agreement's options whole" "$(cat "$fixture/etc/modprobe.conf" 2>&1)"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
echo not-ready >"$fixture/activation"
! run touchid-enable >/dev/null 2>&1 && [[ -e $fixture/etc/touchid-on ]] ||
  fail "a Touch ID that doesn't come up keeps the record of an owner who agreed earlier"
echo ready >"$fixture/activation"
machine apple,j414c apple,t6021 apple,arm-platform
touch "$fixture/modprobe-fails"
! out=$(run touchid-enable 2>&1) && [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/touchid-sddm && $out == *"driver did not load"* ]] &&
  ! grep -q 'systemctl start' "$fixture/calls" ||
  fail 'a driver that does not load takes the agreement back and starts nothing' "$out"
rm "$fixture/modprobe-fails"
# A driver already running, as a kernel that loads it read-only on every Mac
# leaves it, can't be told to write until it loads again: the agreement stands.
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module"
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ -e $fixture/etc/touchid-on && -e $fixture/etc/modprobe.conf && $out == *"turns on when this Mac restarts"* ]] ||
  fail 'a driver loaded before it could write keeps the agreement for the next boot' "$out"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module"
echo ready >"$fixture/activation"
run touchid-enable >/dev/null 2>&1 || fail 'a driver already running that writes by default turns on now'
[[ -e $fixture/etc/touchid-sddm ]] || fail 'turning it on records the agreement to the SDDM login'
# SDDM's login screen is best effort: a PAM stack this package does not manage never undoes setup.
mkdir -p "$fixture/pam"
printf 'auth required pam_deny.so\n' >"$fixture/pam/sddm"
out=$(run touchid-enable 2>&1) && [[ $out == *"login screen is unchanged"* && -e $fixture/etc/touchid-on && $(<"$fixture/pam/sddm") == 'auth required pam_deny.so' ]] ||
  fail "a custom SDDM PAM stack is reported, kept, and doesn't fail setup" "$out"
rm -rf "$fixture/pam"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/module" "$fixture/etc"
touch "$fixture/etc/modprobe.conf"
echo not-ready >"$fixture/activation"
! out=$(run touchid-enable 2>&1) && [[ $out == *"did not become ready (not-ready)"* && $out != *"turns on when this Mac restarts"* ]] ||
  fail 'a driver loaded with the options already in place that still fails says so, not that a restart will fix it' "$out"
echo ready >"$fixture/activation"
machine apple,j314s apple,t6000 apple,arm-platform
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/etc/touchid-on ]] || fail 'an unsupported Mac is never turned on'
pass 'turning Touch ID on carves what is missing, records the agreement, and succeeds only when it is ready'

# The entrypoints use fixed paths; rewritten copies point them at the fixture.
entry=$work/entry
mkdir -p "$entry"
for name in enable-fingerprint disable-fingerprint; do
  sed -e "s|/run/omarchy-mac/touchid|$fixture/run/touchid|g" -e "s|/var/lib/aurora-sep-keybag.bin|$fixture/keybag|g" \
    -e "s|/usr/lib/omarchy-mac/touchid-enable|$fixture/bin/enable-stub|g" -e "s|/etc/omarchy-mac/touchid-on|$fixture/etc/touchid-on|g" \
    -e "s|/usr/lib/omarchy-mac/touchid-eligibility|$fixture/bin/eligibility-stub|g" \
    -e "s|/usr/lib/omarchy-mac/touchid-sddm|$ROOT/lib/touchid-sddm|g" -e "s|/etc/omarchy-mac/touchid-sddm|$fixture/etc/touchid-sddm|g" \
    -e "s|/etc/modprobe.d/omarchy-mac-touchid.conf|$fixture/etc/modprobe.conf|g" -e "s|/usr/lib/firmware/updates/|$fixture/firmware/updates/|g" \
    -e "s|/proc/device-tree/compatible|$tree/compatible|g" -e "s|flock -w 300|flock -w 0|" "$ROOT/entrypoints/$name" >"$entry/$name"
  chmod +x "$entry/$name"
done
printf '#!/bin/sh\necho enable >>"%s"\nexit 0\n' "$fixture/calls" >"$fixture/bin/enable-stub"
printf '#!/bin/sh\ncat "%s"\n' "$fixture/eligibility" >"$fixture/bin/eligibility-stub"
chmod +x "$fixture/bin/enable-stub" "$fixture/bin/eligibility-stub"
ask() {
  : >"$fixture/calls"
  printf '%s\n' "$2" >"$fixture/answer"
  echo "$1" >"$fixture/run/touchid"
  PATH="$fixture/bin:$PATH" "$entry/enable-fingerprint" <"$fixture/answer" >"$fixture/out" 2>&1
}
machine apple,j414c apple,t6021 apple,arm-platform
! ask available n && grep -q 'Touch ID stays off' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'an owner who says no turns nothing on' "$(<"$fixture/out")"
! ask available '' && [[ ! -s $fixture/calls ]] || fail 'no answer is no'
! PATH="$fixture/bin:$PATH" "$entry/enable-fingerprint" </dev/null >"$fixture/out" 2>&1 && [[ ! -s $fixture/calls ]] ||
  fail 'a closed terminal is no'
grep -q 'creates a key store' "$fixture/out" && grep -q 'anti-replay state' "$fixture/out" &&
  grep -q 'both systems update it' "$fixture/out" && grep -q 'With FileVault on' "$fixture/out" &&
  grep -q 'DFU' "$fixture/out" && grep -q 'With FileVault off' "$fixture/out" &&
  grep -q 'up anything on macOS you still need' "$fixture/out" && grep -q 'The key store stays' "$fixture/out" ||
  fail 'the owner is told about the shared state, the worst case for each FileVault setting and what stays' "$(<"$fixture/out")"
! grep -qE "sensor's key|earlier Touch ID setup" "$fixture/out" ||
  fail "a Mac that isn't a Neo, with no key store yet, is told nothing that applies only to others" "$(<"$fixture/out")"
ask available y && grep -Fxq enable "$fixture/calls" || fail 'an owner who says yes turns Touch ID on'
neo
touch "$fixture/keybag"
! ask available n && grep -q "reads the sensor's key from the factory records" "$fixture/out" &&
  grep -q 'only root can' "$fixture/out" && grep -q 'Turning Touch ID off deletes that file' "$fixture/out" &&
  grep -q 'earlier Touch ID setup created' "$fixture/out" && ! grep -q 'creates a key store' "$fixture/out" ||
  fail 'a Neo with a key store is told what applies to it' "$(<"$fixture/out")"
[[ -z $(key_copies) ]] || fail "a Neo whose owner says no has no copy of its sensor key" "$(key_copies)"
awk 'length > 80 { exit 1 }' "$fixture/out" || fail 'the prompt fits in 80 columns' "$(<"$fixture/out")"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
ask ready '' && [[ ! -s $fixture/calls && ! -s $fixture/out ]] || fail 'a Touch ID the owner already turned on asks nothing'
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" ||
  fail 'a Touch ID turned on before the driver options existed gets them'
# No options yet, and none can be written.
rm "$fixture/etc/modprobe.conf"
mkdir -p "$fixture/etc/modprobe.conf.new/in-the-way"
! ask ready '' && grep -q 'options could not be written' "$fixture/out" && [[ ! -e $fixture/etc/modprobe.conf ]] ||
  fail "options that can't be written for an earlier agreement fail" "$(<"$fixture/out")"
rm -rf "$fixture/etc/modprobe.conf.new"
rm "$fixture/etc/touchid-on"
! ask ready n && grep -q 'With FileVault on' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'a Touch ID turned off earlier this boot asks again before turning back on'
# Where Touch ID can't be set up, the setup goes on, so a USB reader enrols.
ask failed '' && grep -q 'Restart this Mac' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'a Touch ID that failed this boot lets setup go on and says to restart' "$(<"$fixture/out")"
ask unsupported:board '' && grep -q 'unsupported:board' "$fixture/out" && grep -q 'any other fingerprint reader' "$fixture/out" &&
  ! grep -q 'Restart this Mac' "$fixture/out" &&
  [[ ! -s $fixture/calls ]] || fail 'an unsupported Mac is told why, turns nothing on, and lets the setup go on' "$(<"$fixture/out")"
without_status() {
  : >"$fixture/calls"
  rm -f "$fixture/run/touchid"
  printf '%s\n' "$1" >"$fixture/eligibility"
  printf '%s\n' "$2" | PATH="$fixture/bin:$PATH" "$entry/enable-fingerprint" >"$fixture/out" 2>&1
}
without_status none '' && [[ ! -s $fixture/out && ! -s $fixture/calls ]] ||
  fail 'a Mac with no sensor, which records no status, lets the setup go on and says nothing' "$(<"$fixture/out")"
! without_status available n && grep -q 'With FileVault on' "$fixture/out" && grep -q 'Touch ID stays off' "$fixture/out" &&
  [[ ! -s $fixture/calls ]] ||
  fail 'a status service that failed is worked out again, and an available Mac still asks' "$(<"$fixture/out")"
without_status unsupported:m1-family '' && grep -q 'unsupported:m1-family' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'an M1 Mac with no status lets the setup go on' "$(<"$fixture/out")"
# An agreed Mac gets its options whatever its status: a driver loaded read-only
# without them reads blocked, and reaches ready only once they exist.
touch "$fixture/etc/touchid-on"
rm -f "$fixture/etc/modprobe.conf"
ask blocked '' && grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" &&
  grep -q 'Restart this Mac' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
  fail 'an agreed Mac that reads blocked gets its options and is told to restart' "$(<"$fixture/out")"
# An agreed Mac whose activation hasn't answered is never asked again, so a no
# can't claim to leave on a Touch ID that is on.
without_status available n && ! grep -qE 'With FileVault on|stays off' "$fixture/out" && grep -q "isn't ready yet (no status)" "$fixture/out" &&
  [[ -e $fixture/etc/touchid-on && ! -s $fixture/calls ]] ||
  fail 'an agreed Mac with no status is told to restart, not asked again' "$(<"$fixture/out")"
# SDDM's login screen reaches only an owner who was told about it, and never stops setup.
omarchy_pam() {
  mkdir -p "$fixture/pam"
  printf '#%%PAM-1.0\nauth include system-login\naccount include system-login\npassword include system-login\nsession include system-login\n' >"$fixture/pam/sddm"
  printf 'auth required pam_shells.so\nauth requisite pam_nologin.so\nauth include system-auth\naccount required pam_access.so\n' >"$fixture/pam/system-login"
  printf 'auth required pam_faillock.so preauth silent deny=10 unlock_time=120\n-auth [success=2 default=ignore] pam_systemd_home.so\nauth [success=1 default=bad] pam_unix.so try_first_pass nullok\nauth [default=die] pam_faillock.so authfail deny=10 unlock_time=120\nauth optional pam_permit.so\nauth required pam_env.so\nauth required pam_faillock.so authsucc\n' >"$fixture/pam/system-auth"
}
rm -rf "$fixture/pam"
omarchy_pam
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
rm -f "$fixture/etc/touchid-sddm"
ask ready '' && [[ ! -e $fixture/pam/omarchy-mac-touchid ]] && ! grep -q 'omarchy-mac-touchid' "$fixture/pam/sddm" ||
  fail 'a Mac that agreed before the login screen change is not given it unasked' "$(<"$fixture/out")"
touch "$fixture/etc/touchid-sddm"
ask ready '' && grep -Fxq 'auth requisite pam_faillock.so preauth silent deny=10 unlock_time=120' "$fixture/pam/omarchy-mac-touchid" &&
  grep -Fxq 'auth include omarchy-mac-touchid' "$fixture/pam/sddm" ||
  fail 'an Omarchy Mac that agreed to the login screen change gets it' "$(<"$fixture/out")"
rm -f "$fixture/pam/omarchy-mac-touchid"
omarchy_pam
printf 'auth required pam_deny.so\n' >>"$fixture/pam/sddm"
ask ready '' && grep -q 'left as it is' "$fixture/out" && [[ ! -e $fixture/pam/omarchy-mac-touchid ]] ||
  fail 'a custom SDDM stack is reported but never stops the fingerprint setup' "$(<"$fixture/out")"
rm -rf "$fixture/pam"
rm -f "$fixture/etc/touchid-sddm"
rm -f "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] &&
  grep -q 'key store for Linux stays' "$fixture/out" || fail "turning it off removes the owner's agreement and says the key store stays"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 || fail 'turning it off twice is fine'
# A PAM file that is not ours never blocks turning Touch ID off; one that still
# includes our policy is kept and reported, and consent goes either way.
mkdir -p "$fixture/pam" "$fixture/etc" "$fixture/firmware/updates/apple"
printf 'administrator PAM\n' >"$fixture/pam/custom"
ln -s custom "$fixture/pam/sddm"
touch "$fixture/etc/touchid-on" "$fixture/etc/touchid-sddm" "$fixture/etc/modprobe.conf"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 &&
  [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/touchid-sddm && ! -e $fixture/etc/modprobe.conf && -L $fixture/pam/sddm && -z $(key_copies) ]] &&
  [[ $(<"$fixture/pam/custom") == "administrator PAM" ]] ||
  fail 'a symlinked SDDM file without our policy neither blocks removal nor changes' "$(<"$fixture/out")"
printf '# omarchy-mac Touch ID\nauth include omarchy-mac-touchid\n' >"$fixture/pam/custom"
touch "$fixture/etc/touchid-on" "$fixture/etc/touchid-sddm" "$fixture/etc/modprobe.conf"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 &&
  [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/touchid-sddm && ! -e $fixture/etc/modprobe.conf && -L $fixture/pam/sddm && -z $(key_copies) ]] &&
  grep -q 'review it' "$fixture/out" ||
  fail 'a symlinked SDDM file that includes our policy is kept and reported while consent is removed' "$(<"$fixture/out")"
rm "$fixture/pam/sddm" "$fixture/pam/custom"
printf 'administrator owned policy\n' >"$fixture/pam/omarchy-mac-touchid"
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 &&
  [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] &&
  [[ $(<"$fixture/pam/omarchy-mac-touchid") == "administrator owned policy" ]] ||
  fail 'edited owned PAM policy is preserved while boot consent is removed' "$(<"$fixture/out")"
rm "$fixture/pam/omarchy-mac-touchid"
# A Neo's sensor key goes too, since turning Touch ID on again rebuilds it.
mkdir -p "$fixture/firmware/updates/apple" "$fixture/etc"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
touch "$fixture/etc/touchid-on"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 && [[ -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] ||
  fail "turning it off deletes a Neo's sensor key" "$(key_copies)"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 && [[ -z $(key_copies) ]] ||
  fail "turning it off deletes a sensor key left by an earlier one" "$(key_copies)"
printf partial >"$fixture/firmware/updates/apple/msrk-j700.bin.new"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 && [[ -z $(key_copies) ]] ||
  fail "turning it off deletes an interrupted rebuild's temporary copy" "$(key_copies)"
# An agreed Mac's options are written under the lock too, so a removal running
# now can't be undone.
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
rm -f "$fixture/etc/modprobe.conf"
exec {held}>>"$fixture/run/touchid.lock"
flock "$held"
! ask ready '' && grep -q 'another Touch ID setup or removal is still running' "$fixture/out" && [[ ! -e $fixture/etc/modprobe.conf ]] ||
  fail "an agreed Mac's options wait for the lock" "$(<"$fixture/out")"
exec {held}>&-
# A lock that can't be opened is said to be so, not taken for a setup running.
rm -f "$fixture/run/touchid.lock"
mkdir "$fixture/run/touchid.lock"
! ask ready '' && grep -q 'could not be opened' "$fixture/out" && [[ ! -e $fixture/etc/modprobe.conf ]] ||
  fail "an agreed Mac whose lock can't be opened says so" "$(<"$fixture/out")"
rm "$fixture/etc/touchid-on"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && grep -q 'could not be opened' "$fixture/out" ||
  fail "a removal whose lock can't be opened says so" "$(<"$fixture/out")"
rmdir "$fixture/run/touchid.lock"
# A removal waits for a setup still running, which could install its key after.
touch "$fixture/etc/touchid-on"
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
exec {held}>>"$fixture/run/touchid.lock"
flock "$held"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && grep -q 'another Touch ID setup is still running' "$fixture/out" &&
  [[ -e $fixture/etc/touchid-on && -n $(key_copies) ]] || fail "a removal that can't take the lock removes nothing" "$(<"$fixture/out")"
exec {held}>&-
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 && [[ -z $(key_copies) && ! -e $fixture/etc/touchid-on ]] ||
  fail "a removal goes on once the lock is free" "$(key_copies)"
mkdir -p "$fixture/etc/touchid-on/in-the-way"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && grep -q 'could not be turned off' "$fixture/out" &&
  ! grep -q 'stops loading' "$fixture/out" ||
  fail "a record that can't be removed fails and never says Touch ID stops loading" "$(<"$fixture/out")"
rm -rf "$fixture/etc/touchid-on"
touch "$fixture/keybag"
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && ! -s $fixture/calls ]] ||
  fail 'after turning it off, the next boot leaves it off and only offers it again'
pass 'enable-fingerprint asks before anything turns on, and turning it off lasts'

if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon modprobe udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  for name in status load; do
    systemd-analyze --root="$work/root" verify --man=no "/usr/lib/systemd/system/omarchy-mac-touchid-$name.service" 2>"$work/verify" ||
      fail "systemd accepts the $name unit" "$(cat "$work/verify")"
  done
  pass 'systemd accepts the Touch ID status and load units'
fi
