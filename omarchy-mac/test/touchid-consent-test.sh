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
grep -Fxq 'ConditionPathExists=/etc/omarchy-mac/touchid-on' "$load" && grep -Fxq 'ExecStart=/usr/bin/flock -w 20 /run/omarchy-mac/touchid.lock /usr/lib/omarchy-mac/touchid-load --boot' "$load" &&
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
mkdir -p "$fixture/bin" "$fixture/extractors"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
# The stub keeps the driver options it was loaded with, as modprobe reads them.
# With no-node or no-keybag, the driver loads but that never appears.
cat >"$fixture/bin/modprobe" <<'SH'
#!/bin/bash
fixture=${OMARCHY_MAC_TOUCHID_TREE%/*}
case $1 in
  --showconfig) cat "$OMARCHY_MAC_TOUCHID_OPTIONS" "$fixture/admin-options"; exit $? ;;
  -a)
    echo "modprobe $*" >>"$fixture/calls"
    [[ ! -f $fixture/replace-image ]] || echo old >"$fixture/apple-sep.ko.zst"
    exit 0 ;;
esac
echo "modprobe $*" >>"$fixture/calls"
cp "$OMARCHY_MAC_TOUCHID_OPTIONS" "$fixture/options-at-load"
[[ ! -e $fixture/modprobe-fails ]] || exit 1
mkdir -p "$fixture/module"
[[ -e $fixture/no-node ]] || touch "$fixture/sep-bio"
[[ -e $fixture/no-keybag ]] || touch "$fixture/keybag"
SH
cat >"$fixture/bin/systemctl" <<'SH'
#!/bin/bash
fixture=${OMARCHY_MAC_TOUCHID_TREE%/*}
echo "systemctl $*" >>"$fixture/calls"
if [[ $1 == start ]]; then
  if [[ -f $fixture/real-activation ]]; then
    "$OMARCHY_MAC_TOUCHID_HELPERS/touchid-kernel-ready" activate &&
      "$OMARCHY_MAC_TOUCHID_HELPERS/touchid-activate"
  else
    cat "$fixture/activation" >"$fixture/run/touchid"
  fi
fi
SH
printf '#!/bin/sh\n[ -e "%s" ] || echo /usr/lib/omarchy/mac/enable-fingerprint\n' "$fixture/no-hook" >"$fixture/bin/omarchy-lifecycle-dispatch"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/sleep"
cat >"$fixture/bin/mv" <<'SH'
#!/bin/bash
fixture=${OMARCHY_MAC_TOUCHID_TREE%/*}
case $* in
  *".omarchy-mac-touchid."*) [[ ! -e $fixture/options-mv-fails ]] || exit 1 ;;
esac
exec /usr/bin/mv "$@"
SH
# The module in the fixture carries its own metadata. A replacement between
# the capability check and insertion changes only the installed copy.
cat >"$fixture/bin/modinfo" <<'SH'
#!/bin/bash
fixture=${OMARCHY_MAC_TOUCHID_TREE%/*}
image=${!#}
[[ $image != apple_sep ]] || image="$fixture/apple-sep.ko.zst"
case $1 in
  -n) printf '%s\n' "$image" ;;
  -p) sed -n 's/^param=//p' "$image" ;;
  -F) sed -n "s/^$2=//p" "$image" ;;
  *) exit 1 ;;
esac
SH
cat >"$fixture/bin/insmod" <<'SH'
#!/bin/bash
fixture=${OMARCHY_MAC_TOUCHID_TREE%/*}
image=$1
shift
echo "insmod $*" >>"$fixture/calls"
[[ ! -d $fixture/module && ! -e $fixture/raced-load ]] || exit 1
cmp -s "$image" "$fixture/expected-image" || exit 1
mkdir -p "$fixture/module/notes" "$fixture/driver/test.sep/diag"
echo guarded-build >"$fixture/module/notes/.note.gnu.build-id"
echo enabled >"$fixture/driver/test.sep/diag/xart"
echo 1 >"$fixture/driver/test.sep/diag/xart_guard"
echo 1 >"$fixture/driver/test.sep/diag/xart_guard_pins"
for attribute in touchid:ready sensor_attach:attached restore:empty matching:unverified; do
  echo "${attribute#*:}" >"$fixture/driver/test.sep/diag/${attribute%:*}"
done
touch "$fixture/sep-bio"
[[ -e $fixture/keybag ]] || touch "$fixture/keybag"
SH
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
# A 16-inch M4 Pro's: the same MSRk, an FSC2 calibration, and a seal naming
# its SoC; the key and the calibration they make.
fsc2_im4p = der(0x30, der(0x16, b"IM4P") + der(0x16, b"FSC2") + der(0x16, b"1") + der(0x04, b"c" * 2500))
fsc2 = der(0x30, der(0x16, b"IMG4") + fsc2_im4p + der(0xA0, der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x01") + b"\x31\x00")))
j616s_seal = der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x00") + der(0x04, b"m" * 900))
archive("j616s.tar.gz", [("MSRk-00003356-AA", msrk), ("FSC2-00003356-AA", fsc2), ("seal-00006040-001E", j616s_seal),
                         (named, trust), ("trustobject-current", trust)])
archive("j616s-other-chip.tar.gz", [("MSRk-00003356-AA", msrk), ("FSC2-00003356-AA", fsc2), ("seal-00008140-001E", j616s_seal),
                                    (named, trust), ("trustobject-current", trust)])
with open(os.path.join(out, "j616s-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + msrk + filler(4096) + fsc2 + j616s_seal + trust + filler(1 << 20))
# One holding all but the MSRk record: the calibration rebuilds, the key can't.
with open(os.path.join(out, "j616s-no-key-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + fsc2 + j616s_seal + trust + filler(1 << 20))
for name, payload in (("j616s-key.bin", im4p), ("j616s-cal.bin", fsc2_im4p)):
    image = der(0x30, der(0x16, b"IMG4") + payload + der(0xA0, j616s_seal))
    with open(os.path.join(out, name), "wb") as fd:
        fd.write(der(0x30, der(0x16, b"comb") + der(0x30, der(0x16, b"fdrd") + der(0x04, image))
                           + der(0x30, der(0x16, b"secb") + der(0x04, trust))))
# A 16-inch M4 Max's: the same records, sealed for its own SoC (T6041). Its
# M4 Pro sibling's seal must not pass for it.
j616c_seal = der(0x30, der(0x16, b"IM4M") + der(0x02, b"\x00") + der(0x04, b"x" * 900))
archive("j616c.tar.gz", [("MSRk-00003356-AA", msrk), ("FSC2-00003356-AA", fsc2), ("seal-00006041-001E", j616c_seal),
                         (named, trust), ("trustobject-current", trust)])
archive("j616c-other-chip.tar.gz", [("MSRk-00003356-AA", msrk), ("FSC2-00003356-AA", fsc2), ("seal-00006040-001E", j616c_seal),
                                    (named, trust), ("trustobject-current", trust)])
with open(os.path.join(out, "j616c-isc.img"), "wb") as fd:
    fd.write(filler(1 << 20) + msrk + filler(4096) + fsc2 + j616c_seal + trust + filler(1 << 20))
for name, payload in (("j616c-key.bin", im4p), ("j616c-cal.bin", fsc2_im4p)):
    image = der(0x30, der(0x16, b"IMG4") + payload + der(0xA0, j616c_seal))
    with open(os.path.join(out, name), "wb") as fd:
        fd.write(der(0x30, der(0x16, b"comb") + der(0x30, der(0x16, b"fdrd") + der(0x04, image))
                           + der(0x30, der(0x16, b"secb") + der(0x04, trust))))
PY
python3 -I "$work/factory.py" "$work/factory"
# Any copy of the sensor key under the fixture other than the one named.
key_copies() {
  find "$fixture" -name 'msrk-j700.bin*' ! -path "${1:-/nonexistent}"
}

# A device tree: the machine's compatible list, a sensor node, and the identity.
machine() {
  rm -rf "$tree" "$fixture/firmware" "$fixture/run" "$fixture/etc" "$fixture/sep-bio" "$fixture/keybag" "$fixture/calls" "$fixture/no-hook" "$fixture/no-node" "$fixture/no-keybag" "$fixture/options-at-load" "$fixture/module" \
    "$fixture/esp" "$fixture/modinfo-params" "$fixture/guard-list" "$fixture/list-at-load" "$fixture/mv-fails" "$fixture"/aurora-sep-touchid-retry-*
  rm -rf "$fixture/driver" "$fixture/raced-load" "$fixture/replace-image" "$fixture/options-mv-fails" "$fixture/eligibility" "$fixture/real-activation"
  : >"$fixture/admin-options"
  printf '%s\n' xart_guard_pins_abi=1 t6000_registration=1 depends=macsmc,ecdh_generic \
    param=xart_guard: param=xart_guard_pins: param=xart_writes: param=provision_keybag: >"$fixture/apple-sep.ko.zst"
  cp "$fixture/apple-sep.ko.zst" "$fixture/expected-image"
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
  local executable=$ROOT/lib/$1
  [[ $1 != /* ]] || executable=$1
  PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_TREE=$tree OMARCHY_MAC_TOUCHID_FIRMWARE=$fixture/firmware \
    OMARCHY_MAC_TOUCHID_EXTRACTORS=$fixture/extractors OMARCHY_MAC_TOUCHID_AGREED=$fixture/etc/touchid-on \
    OMARCHY_MAC_TOUCHID_OPTIONS=$fixture/etc/modprobe.conf OMARCHY_MAC_TOUCHID_MODULE=$fixture/module OMARCHY_MAC_TOUCHID_DRIVER=$fixture/driver \
    OMARCHY_MAC_TOUCHID_STATUS=$fixture/run/touchid OMARCHY_MAC_TOUCHID_HELPERS=$ROOT/lib \
    OMARCHY_MAC_TOUCHID_NODE=$fixture/sep-bio OMARCHY_MAC_TOUCHID_KEYBAG=$fixture/keybag \
    OMARCHY_MAC_TOUCHID_GUARD_LIST=$fixture/guard-list \
    OMARCHY_MAC_TOUCHID_ESP=$fixture/esp OMARCHY_MAC_TOUCHID_CONTAINER=${container:-$work/factory/isc.img} \
    OMARCHY_MAC_TOUCHID_PYTHON=${python:-python3} OMARCHY_MAC_PAMD=$fixture/pam.d \
    OMARCHY_MAC_TOUCHID_PAM_LOCK=$fixture/run/touchid-pam.lock OMARCHY_MAC_TOUCHID_PAM_MODULE=$fixture/pam_aurora_touchid.so \
    "$executable" "${@:2}"
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
machine apple,j314c apple,t6001 apple,arm-platform
[[ $(eligibility) == "unsupported:m1-family" ]] || fail 'the 14-inch M1 Max still waits for a board test'
passive_options=$'blacklist apple_sep\noptions apple_sep xart_writes=0 provision_keybag=0'
for board in "apple,j313 apple,t8103" "apple,j316c apple,t6001"; do
  read -r model chip <<<"$board"
  machine "$model" "$chip" apple,arm-platform
  [[ $(eligibility) == available && $(run touchid-options) == "$passive_options" ]] ||
    fail "$model requires guarded setup and keeps automatic loads read-only"
  for capability in param=xart_guard: param=xart_guard_pins: param=xart_writes: param=provision_keybag: xart_guard_pins_abi=1; do
    grep -Fxv "$capability" "$fixture/expected-image" >"$fixture/apple-sep.ko.zst"
    [[ $(eligibility) == unsupported:kernel ]] || fail "$model requires $capability"
  done
  grep -Fxv t6000_registration=1 "$fixture/expected-image" >"$fixture/apple-sep.ko.zst"
  if [[ $model == apple,j316c ]]; then
    [[ $(eligibility) == unsupported:kernel ]] || fail 'J316c requires both sensor registration recoveries'
  else
    [[ $(eligibility) == available ]] || fail 'J313 has no T6000 registration dependency'
  fi
  cp "$fixture/expected-image" "$fixture/apple-sep.ko.zst"
  diag=$fixture/driver/test.sep/diag
  mkdir -p "$fixture/module/notes" "$diag"
  [[ $(eligibility) == available ]] && ! run touchid-kernel-ready activate || fail 'binding may finish after the invitation'
  echo disabled >"$diag/xart"
  [[ $(eligibility) == available ]] && ! run touchid-kernel-ready activate || fail 'a read-only load can record consent only'
  echo enabled >"$diag/xart"
  echo 0 >"$diag/xart_guard"
  [[ $(eligibility) == unsupported:restart ]] || fail "$model rejects writable, unguarded preloads"
  echo 1 >"$diag/xart_guard"
  echo 0 >"$diag/xart_guard_pins"
  [[ $(eligibility) == unsupported:restart ]] || fail "$model rejects writable preloads without pins"
  echo 1 >"$diag/xart_guard_pins"
  echo running >"$fixture/module/notes/.note.gnu.build-id"
  echo previous >"$fixture/run/touchid-guarded-build-id"
  [[ $(eligibility) == unsupported:restart ]] && ! run touchid-kernel-ready activate || fail 'another running module cannot inherit authorization'
  cp "$fixture/module/notes/.note.gnu.build-id" "$fixture/run/touchid-guarded-build-id"
  [[ $(eligibility) == available ]] && run touchid-kernel-ready activate || fail 'activation verifies the running module and its effective policy'
done
machine apple,j293 apple,t8103 apple,arm-platform
[[ $(eligibility) == "unsupported:m1-family" ]] || fail 'other M1 machines remain out of scope'
machine apple,j414c apple,t6021 apple,arm-platform
: >"$fixture/modinfo-params"
run touchid-kernel-ready || fail "the boot-time load never checks the pins on a Mac other than the M1 Air"
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
mkdir -p "$fixture/pam.d"
touch "$fixture/pam_aurora_touchid.so"
printf 'auth include system-auth\naccount include system-auth\n' >"$fixture/pam.d/sudo"
out=$(run touchid-enable 2>&1) || fail 'an available Mac whose activation reads ready turns on' "$out"
grep -Fxq -- '-auth      optional                    pam_aurora_touchid.so' "$fixture/pam.d/sudo" ||
  fail "a password in sudo re-arms Touch ID once it is on" "$(<"$fixture/pam.d/sudo")"
[[ $(<"$fixture/firmware/updates/apple/mesa_calibration.bin") == "calibration" ]] ||
  fail 'the calibration is carved into the updates firmware directory under the default name'
[[ -f $fixture/etc/touchid-on && $(stat -c %a "$fixture/etc/touchid-on") == 644 ]] || fail "the owner's agreement is recorded"
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/options-at-load" &&
  [[ $(stat -c %a "$fixture/etc/modprobe.conf") == 644 ]] ||
  fail "the driver is loaded with the options that let it write, which a read-only default needs"
[[ $(<"$fixture/calls") == $'calibration\nmodprobe apple-sep\nsystemctl start omarchy-mac-touchid-activate.service\nsystemctl try-restart fprintd.service' ]] ||
  fail 'it carves, loads the driver, waits for the activation, then restarts a running fprintd' "$(<"$fixture/calls")"
[[ $out == *"Touch ID is on."* ]] || fail 'it says so' "$out"
! grep -q xart_guard "$fixture/etc/modprobe.conf" || fail 'a Mac other than the M1 Air gets no xART guard option'
# Build the two fixed records from the driver's little-endian formats. Its
# refused keybag proves that no bag was created. An intent never proves that.
recovery_records() {
  python3 - "$fixture" "${1:-cold setup spent}" <<'PYTHON'
import binascii, pathlib, struct, sys, zlib
root = pathlib.Path(sys.argv[1])
crc = binascii.crc_hqx(struct.pack("<4I", 2, 2, 0, 0) + bytes(16), 0xffff)
(root / "keybag").write_bytes(b"APPLE-SEP-KBAG01" + struct.pack("<4I", 2, 2, 0, crc) + bytes(20))
entry = b"AXGO" + bytes(4) + sys.argv[2].encode("ascii")
(root / "guard-list").write_bytes(entry + struct.pack("<II", zlib.crc32(entry), 0))
PYTHON
}
for board in "apple,j313 apple,t8103" "apple,j316c apple,t6001"; do
  read -r model chip <<<"$board"
  machine "$model" "$chip"
  printf 'apple/mesacal-m1.bin\0' >"$tree/soc/spi@39b108000/fingerprint@0/firmware-name"
  echo ready >"$fixture/activation"
  echo 'options apple_sep xart_guard=1 os_uuid_hi=0x1234' >"$fixture/admin-options"
  if [[ $model == apple,j313 ]]; then recovery_records 'first setup used'; else recovery_records; fi
  cp "$fixture/guard-list" "$work/spent"
  cp "$fixture/keybag" "$work/refused"
  touch "$fixture/replace-image"
  out=$(run touchid-enable 2>&1) || fail "$model turns on after a confirmed refusal" "$out"
  aside=("$fixture"/aurora-sep-touchid-retry-*)
  cmp -s "${aside[0]}/guard-list" "$work/spent" && cmp -s "$fixture/keybag" "$work/refused" &&
    [[ ! -e $fixture/guard-list && $(<"$fixture/firmware/updates/apple/mesacal-m1.bin") == calibration ]] ||
    fail 'only the unused guard list was archived before loading the driver'
  grep -Fxq 'modprobe -a -- macsmc ecdh_generic' "$fixture/calls" &&
    grep -Fxq 'insmod xart_writes=1 provision_keybag=1 xart_guard=1 xart_guard_pins=1 os_uuid_hi=0x1234' "$fixture/calls" &&
    ! grep -Eq '(xart_writes|provision_keybag)=1' "$fixture/etc/modprobe.conf" &&
    [[ $(<"$fixture/apple-sep.ko.zst") == old ]] ||
    fail 'insertion uses the checked module bytes and one value for each parameter, including the existing identity' "$(<"$fixture/calls")"

  for result in intent corrupt refused-with-pins missing-with-list; do
    machine "$model" "$chip"
    recovery_records
    case $result in
      intent) printf '\0' | dd of="$fixture/keybag" bs=1 seek=20 conv=notrunc status=none ;;
      corrupt) printf 'damaged' >>"$fixture/keybag" ;;
      refused-with-pins) printf 'earlier pin' >>"$fixture/guard-list" ;;
      missing-with-list) rm "$fixture/keybag" ;;
    esac
    [[ $(eligibility) == unsupported:recovery ]] && ! run touchid-enable >/dev/null 2>&1 &&
      ! compgen -G "$fixture/aurora-sep-touchid-retry-*" >/dev/null && [[ -s $fixture/guard-list ]] ||
      fail "$model preserves indeterminate state ($result)"
  done
  for state in 1 3; do
    machine "$model" "$chip"
    recovery_records
    printf "\\$(printf %o "$state")" | dd of="$fixture/keybag" bs=1 seek=20 conv=notrunc status=none
    run touchid-retry-aside --recover && [[ -e $fixture/guard-list ]] || fail "committed state $state keeps its guard list"
  done
done
machine apple,j316c apple,t6001
recovery_records
mkdir -p "$fixture/module"
out=$(run touchid-enable 2>&1) && fail 'a binding module must wait for restart'
[[ $out == *'Restart this Mac'* && -s $fixture/guard-list && -e $fixture/etc/touchid-on ]] &&
  ! grep -Eq 'insmod|systemctl start' "$fixture/calls" || fail 'a preload defers activation and recovery without losing consent' "$out"
machine apple,j316c apple,t6001
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
sed -i '/^xart_guard_pins_abi=/d' "$fixture/apple-sep.ko.zst"
echo 'alias=of:N*T*Capple,sep' >>"$fixture/apple-sep.ko.zst"
cp "$fixture/apple-sep.ko.zst" "$fixture/expected-image"
recovery_records
run touchid-load --boot && grep -Fxq 'insmod xart_writes=0 provision_keybag=0' "$fixture/calls" &&
  [[ -s $fixture/guard-list && ! -e $fixture/run/touchid-guarded-build-id ]] && ! run touchid-kernel-ready activate ||
  fail 'an autoloading kernel without guarded setup can still boot SEP for the M1 microphones read-only'
machine apple,j313 apple,t8103
echo 'options apple_sep xart_writes=0' >"$fixture/admin-options"
! out=$(run touchid-enable 2>&1) && [[ $out == *'cannot override'* ]] && ! grep -q insmod "$fixture/calls" ||
  fail 'an explicit read-only setting cannot be overridden' "$out"
machine apple,j316c apple,t6001
mkdir -p "$fixture/etc"
printf '%s\n' 'options apple_sep xart_writes=1 provision_keybag=1 xart_guard=1 xart_guard_pins=1' >"$fixture/etc/modprobe.conf"
rm -rf "$tree"
run touchid-options --migrate && ! grep -q 'writes=1' "$fixture/etc/modprobe.conf" &&
  grep -Fxq 'blacklist apple_sep' "$fixture/etc/modprobe.conf" || fail 'upgrading an offline guarded installation withdraws persistent writes'
# Full owner entrypoint with real packaged helpers and activation. Fixed
# production paths are mapped into this root. Only hardware and services are simulated.
machine apple,j316c apple,t6001
sed -e "s|/usr/lib/omarchy-mac/|$ROOT/lib/|g" -e "s|/run/omarchy-mac/|$fixture/run/|g" \
  -e "s|/etc/omarchy-mac/touchid-on|$fixture/etc/touchid-on|g" "$ROOT/entrypoints/enable-fingerprint" >"$work/owner-setup"
chmod +x "$work/owner-setup"
touch "$fixture/real-activation"
run touchid-status
out=$(run "$work/owner-setup" <<<yes 2>&1) && [[ $(<"$fixture/run/touchid") == ready && -e $fixture/etc/touchid-on ]] ||
  fail 'the J316c owner can accept, load the checked driver and activate through the packaged entrypoint' "$out"
rm -rf "$fixture/module" "$fixture/driver" "$fixture/run"
mkdir "$fixture/run"
sed -i '/^xart_guard_pins_abi=/d' "$fixture/apple-sep.ko.zst"
: >"$fixture/calls"
! run touchid-load && ! run touchid-kernel-ready activate && ! grep -qE 'insmod|modprobe [^ -]' "$fixture/calls" &&
  ! grep -q 'writes=1' "$fixture/etc/modprobe.conf" || fail 'an agreed M1 on an older kernel grants no automatic or explicit writes'
machine apple,j316c apple,t6001
touch "$fixture/raced-load"
! run touchid-enable >/dev/null 2>&1 && [[ ! -e $fixture/run/touchid-guarded-build-id && ! -e $fixture/etc/touchid-on ]] &&
  ! grep -q 'systemctl start' "$fixture/calls" || fail 'a concurrent external insertion never acquires activation permission'
machine apple,j316c apple,t6001
printf '#!/bin/sh\nexit 1\n' >"$fixture/bin/omarchy-hw-apple-silicon"
! run touchid-options --write && [[ ! -e $fixture/etc/modprobe.conf ]] || fail 'off Apple Silicon no empty options file can be installed'
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
# A Mac other than the M1 Air never moves its list.
machine apple,j414c apple,t6021 apple,arm-platform
printf 'kept' >"$fixture/guard-list"
echo ready >"$fixture/activation"
out=$(run touchid-enable 2>&1) || fail 'an M2 Max turns on' "$out"
[[ $(<"$fixture/guard-list") == "kept" ]] || fail "an M2 Max's guard list is never set aside" "$out"
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
mkdir -p "$fixture/etc"
touch "$fixture/options-mv-fails"
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
! out=$(run touchid-enable 2>&1) && [[ ! -e $fixture/etc/touchid-on && $out == *"driver did not load"* ]] &&
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
    -e "s|/usr/lib/omarchy-mac/touchid-pam|$fixture/bin/pam-stub|g" \
    -e "s|/usr/lib/omarchy-mac/touchid-options|OMARCHY_MAC_TOUCHID_TREE=$tree OMARCHY_MAC_TOUCHID_OPTIONS=$fixture/etc/modprobe.conf OMARCHY_MAC_TOUCHID_HELPERS=$ROOT/lib $ROOT/lib/touchid-options|g" \
    -e "s|/etc/modprobe.d/omarchy-mac-touchid.conf|$fixture/etc/modprobe.conf|g" -e "s|/usr/lib/firmware/updates/|$fixture/firmware/updates/|g" \
    -e "s|/proc/device-tree/compatible|$tree/compatible|g" -e "s|flock -w 300|flock -w 0|" "$ROOT/entrypoints/$name" >"$entry/$name"
  chmod +x "$entry/$name"
done
printf '#!/bin/sh\necho enable >>"%s"\nexit 0\n' "$fixture/calls" >"$fixture/bin/enable-stub"
printf '#!/bin/sh\ncat "%s" 2>/dev/null || echo available\n' "$fixture/eligibility" >"$fixture/bin/eligibility-stub"
printf '#!/bin/sh\nif [ -e "%s" ]; then echo add >>"%s"; else echo remove >>"%s"; fi\n' \
  "$fixture/etc/touchid-on" "$fixture/pam-calls" "$fixture/pam-calls" >"$fixture/bin/pam-stub"
chmod +x "$fixture/bin/enable-stub" "$fixture/bin/eligibility-stub" "$fixture/bin/pam-stub"
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
grep -q 'experimental and can be unstable' "$fixture/out" && grep -q 'Secure Enclave with macOS' "$fixture/out" &&
  grep -q 'back up any data on your macOS partition' "$fixture/out" && grep -q "The Mac manual's" "$fixture/out" ||
  fail 'the owner is told Touch ID is experimental, to back up macOS and where the details are' "$(<"$fixture/out")"
(( $(grep -c . "$fixture/out") <= 4 )) || fail 'the prompt stays at three lines' "$(<"$fixture/out")"
ask available y && grep -Fxq enable "$fixture/calls" || fail 'an owner who says yes turns Touch ID on'
neo
! ask available n && [[ -z $(key_copies) ]] || fail "a Neo whose owner says no has no copy of its sensor key" "$(key_copies)"
awk 'length > 80 { exit 1 }' "$fixture/out" || fail 'the prompt fits in 80 columns' "$(<"$fixture/out")"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
rm -f "$fixture/pam-calls"
ask ready '' && [[ ! -s $fixture/calls && ! -s $fixture/out ]] || fail 'a Touch ID the owner already turned on asks nothing'
[[ $(cat "$fixture/pam-calls" 2>/dev/null) == "add" ]] || fail 'a Touch ID turned on before the re-arm existed gets its PAM lines'
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" ||
  fail 'a Touch ID turned on before the driver options existed gets them'
machine apple,j313 apple,t8103 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
ask ready '' && grep -Fxq 'options apple_sep xart_writes=0 provision_keybag=0' "$fixture/etc/modprobe.conf" ||
  fail 'an M1 Air turned on before the driver options existed gets passive boot options' "$(<"$fixture/out")"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on"
[[ ! -e $fixture/etc/modprobe.conf ]] || fail "the M1 Air's options are gone before the M2 Max runs"
ask ready '' && grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1' "$fixture/etc/modprobe.conf" ||
  fail 'an agreed M2 Max gets its options again, with no pin' "$(<"$fixture/etc/modprobe.conf")"
# No options yet, and none can be written.
rm "$fixture/etc/modprobe.conf"
mkdir -p "$fixture/etc"
touch "$fixture/options-mv-fails"
! ask ready '' && grep -q 'options could not be written' "$fixture/out" && [[ ! -e $fixture/etc/modprobe.conf ]] ||
  fail "options that can't be written for an earlier agreement fail" "$(<"$fixture/out")"
rm -f "$fixture/options-mv-fails"
machine apple,j616c apple,t6041 apple,arm-platform
mkdir -p "$fixture/etc" && touch "$fixture/etc/touchid-on"
ask ready '' && grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1 xart_guard=1' "$fixture/etc/modprobe.conf" ||
  fail 'an M4 Max turned on before the driver options existed gets them with the xART guard on' "$(<"$fixture/out")"
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc" && touch "$fixture/etc/touchid-on"
rm "$fixture/etc/touchid-on"
! ask ready n && grep -q 'experimental' "$fixture/out" && [[ ! -s $fixture/calls ]] ||
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
! without_status available n && grep -q 'experimental' "$fixture/out" && grep -q 'Touch ID stays off' "$fixture/out" &&
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
# The setup hook cannot move the driver's open files, even when an old status
# says activation failed or systemd has not started the new activation yet.
machine apple,j316c apple,t6001
mkdir -p "$fixture/etc" "$fixture/module"
touch "$fixture/etc/touchid-on"
recovery_records
echo available >"$fixture/eligibility"
for status in available unsupported:board not-ready failed unproven blocked; do
  ask "$status" '' && [[ -s $fixture/guard-list && -s $fixture/keybag ]] ||
    fail "an agreed owner hook keeps the open state files for $status"
done
echo unsupported:kernel >"$fixture/eligibility"
ask blocked '' && grep -q "this kernel can't set it up" "$fixture/out" && ! grep -q 'Restart this Mac' "$fixture/out" ||
  fail 'a kernel missing capabilities gets kernel upgrade guidance'
echo unsupported:restart >"$fixture/eligibility"
ask blocked '' && grep -q 'Restart this Mac' "$fixture/out" && ! grep -q 'Boot a kernel' "$fixture/out" ||
  fail 'an unsafe preload on a compatible kernel gets reboot guidance'
machine apple,j414c apple,t6021 apple,arm-platform
mkdir -p "$fixture/etc"
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
# An agreed Mac whose activation hasn't answered is never asked again, so a no
# can't claim to leave on a Touch ID that is on.
without_status available n && ! grep -qE 'experimental|stays off' "$fixture/out" && grep -q "isn't ready yet (no status)" "$fixture/out" &&
  [[ -e $fixture/etc/touchid-on && ! -s $fixture/calls ]] ||
  fail 'an agreed Mac with no status is told to restart, not asked again' "$(<"$fixture/out")"
rm -f "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
touch "$fixture/etc/touchid-on" "$fixture/etc/modprobe.conf"
rm -f "$fixture/pam-calls"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && [[ ! -e $fixture/etc/touchid-on && ! -e $fixture/etc/modprobe.conf ]] &&
  grep -q 'key store for Linux stays' "$fixture/out" || fail "turning it off removes the owner's agreement and says the key store stays"
[[ $(cat "$fixture/pam-calls" 2>/dev/null) == "remove" ]] || fail 'turning it off takes the re-arm out of the PAM stacks, after the record'
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 || fail 'turning it off twice is fine'
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
# The key beside it is removed, so the error names only the record.
cp "$work/factory/key.bin" "$fixture/firmware/updates/apple/msrk-j700.bin"
! PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >"$fixture/out" 2>&1 && grep -q 'could not be turned off' "$fixture/out" &&
  ! grep -q 'stops loading' "$fixture/out" && grep -Fq "remove $fixture/etc/touchid-on" "$fixture/out" && ! grep -q 'msrk' "$fixture/out" ||
  fail "a record that can't be removed fails and never says Touch ID stops loading" "$(<"$fixture/out")"
rm -rf "$fixture/etc/touchid-on"
touch "$fixture/keybag"
run touchid-status
[[ $(<"$fixture/run/touchid") == "available" && ! -s $fixture/calls ]] ||
  fail 'after turning it off, the next boot leaves it off and only offers it again'
pass 'enable-fingerprint asks before anything turns on, and turning it off lasts'

# The 16-inch M4 Pro: its sensor sits on an SPI controller at the root of the
# tree, and its node names a sealed calibration and a sensor root key, both
# rebuilt from its factory records once the owner agrees.
j616s() {
  machine apple,j616s apple,t6040 apple,arm-platform
  rm -rf "$tree/soc"
  mkdir -p "$tree/spi@429108000/fingerprint@0" "$fixture/esp/asahi"
  printf 'apple,mesa-fingerprint\0' >"$tree/spi@429108000/fingerprint@0/compatible"
  printf 'okay\0' >"$tree/spi@429108000/fingerprint@0/status"
  printf 'apple/mesacal-j616s.bin\0apple/msrk-j616s.bin\0' >"$tree/spi@429108000/fingerprint@0/firmware-name"
  cp "$work/factory/j616s.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
}
j616s
[[ $(eligibility) == "available" ]] || fail 'an M4 Pro with its factory records on the ESP is available' "$(eligibility)"
[[ $(run touchid-eligibility sensor) == "$tree/spi@429108000/fingerprint@0" ]] || fail 'its sensor is found at the root of the tree'
rm "$fixture/esp/asahi/all_firmware.tar.gz"
[[ $(eligibility) == "unsupported:no-calibration" ]] || fail "an M4 Pro without its factory records can't rebuild its calibration"
mkdir -p "$fixture/firmware/updates/apple"
cp "$work/factory/j616s-cal.bin" "$fixture/firmware/updates/apple/mesacal-j616s.bin"
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail "an M4 Pro with a calibration but no records can't rebuild its sensor key"
cp "$work/factory/j616s-key.bin" "$fixture/firmware/updates/apple/msrk-j616s.bin"
[[ $(eligibility) == "available" ]] || fail 'an M4 Pro whose calibration and key are installed needs nothing else'
machine apple,j614s apple,t6040 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'a T6040 board the driver has not been tried on is unsupported'
j616s
printf '%s\0' apple,j614s apple,t6040 apple,arm-platform >"$tree/compatible"
[[ $(eligibility) == "unsupported:board" ]] || fail 'an unlisted board whose sensor sits at the root is unsupported too' "$(eligibility)"
j616s
echo ready >"$fixture/activation"
container=$work/factory/j616s-isc.img
out=$(run touchid-enable 2>&1) || fail 'an M4 Pro turns on' "$out"
for file in cal:mesacal-j616s.bin key:msrk-j616s.bin; do
  installed=$fixture/firmware/updates/apple/${file#*:}
  cmp -s "$installed" "$work/factory/j616s-${file%%:*}.bin" && [[ $(stat -c %a "$installed") == 600 && ! -e $installed.new ]] ||
    fail "the M4 Pro's ${file#*:} is rebuilt from its factory records, root-only" "$out"
done
! grep -Fxq calibration "$fixture/calls" || fail "the M4 Pro's calibration is resealed, never carved"
j616s
cp "$work/factory/j616s-other-chip.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
container=$work/factory/j616s-isc.img
! out=$(run touchid-enable 2>&1) && [[ $out == *"is not an M4 Pro MacBook Pro's"* && ! -e $fixture/etc/touchid-on ]] &&
  [[ -z $(find "$fixture/firmware" -name '*j616s*') ]] ||
  fail "records sealed for another SoC give an M4 Pro nothing, and it says why" "$out"
# A calibration rebuilt by a run whose key then can't be read goes with it.
j616s
container=$work/factory/j616s-no-key-isc.img
! out=$(run touchid-enable 2>&1) && [[ $out == *"sensor key could not be read"* && ! -e $fixture/etc/touchid-on ]] &&
  [[ -z $(find "$fixture/firmware" -name '*j616s*') ]] ||
  fail "an M4 Pro whose key can't be read keeps no calibration rebuilt for it" "$out$(find "$fixture/firmware" -name '*j616s*')"
unset container
printf 'apple/mesacal-j616s.bin\0../../etc/shadow\0' >"$tree/spi@429108000/fingerprint@0/firmware-name"
! out=$(run touchid-enable 2>&1) && [[ $out == *"unexpected firmware file"* ]] || fail 'a firmware name outside apple/ is refused' "$out"
mkdir -p "$fixture/firmware/updates/apple" "$fixture/etc"
cp "$work/factory/j616s-key.bin" "$fixture/firmware/updates/apple/msrk-j616s.bin"
cp "$work/factory/j616s-cal.bin" "$fixture/firmware/updates/apple/mesacal-j616s.bin"
printf partial >"$fixture/firmware/updates/apple/mesacal-j616s.bin.new"
touch "$fixture/etc/touchid-on"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 &&
  [[ -z $(find "$fixture/firmware" -name '*j616s*') && ! -e $fixture/etc/touchid-on ]] ||
  fail "turning it off deletes an M4 Pro's sensor key and the calibration rebuilt with it"
pass 'the 16-inch M4 Pro rebuilds its calibration and sensor key from its own factory records'

# The 16-inch M4 Max: the M4 Pro's sensor, wiring and enclave profile on its
# own SoC (T6041), so its records are sealed for 00006041.
j616c() {
  machine apple,j616c apple,t6041 apple,arm-platform
  rm -rf "$tree/soc" "$fixture/firmware/updates" "$fixture/etc/touchid-on"
  mkdir -p "$tree/spi@429108000/fingerprint@0" "$fixture/esp/asahi"
  printf 'apple,mesa-fingerprint\0' >"$tree/spi@429108000/fingerprint@0/compatible"
  printf 'okay\0' >"$tree/spi@429108000/fingerprint@0/status"
  printf 'apple/mesacal-j616c.bin\0apple/msrk-j616c.bin\0' >"$tree/spi@429108000/fingerprint@0/firmware-name"
  cp "$work/factory/j616c.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
}
j616c
[[ $(eligibility) == "available" ]] || fail 'an M4 Max with its factory records on the ESP is available' "$(eligibility)"
rm "$fixture/esp/asahi/all_firmware.tar.gz"
[[ $(eligibility) == "unsupported:no-calibration" ]] || fail "an M4 Max without its factory records can't rebuild its calibration"
mkdir -p "$fixture/firmware/updates/apple"
cp "$work/factory/j616c-cal.bin" "$fixture/firmware/updates/apple/mesacal-j616c.bin"
[[ $(eligibility) == "unsupported:no-root-key" ]] || fail "an M4 Max with a calibration but no records can't rebuild its sensor key"
machine apple,j614c apple,t6041 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'the 14-inch M4 Max, not yet tried, is unsupported'
machine apple,j616s apple,t6041 apple,arm-platform
[[ $(eligibility) == "unsupported:board" ]] || fail 'a board admitted on another SoC is not admitted on T6041'
j616c
echo ready >"$fixture/activation"
container=$work/factory/j616c-isc.img
out=$(run touchid-enable 2>&1) || fail 'an M4 Max turns on' "$out"
for file in cal:mesacal-j616c.bin key:msrk-j616c.bin; do
  installed=$fixture/firmware/updates/apple/${file#*:}
  cmp -s "$installed" "$work/factory/j616c-${file%%:*}.bin" && [[ $(stat -c %a "$installed") == 600 && ! -e $installed.new ]] ||
    fail "the M4 Max's ${file#*:} is rebuilt from its factory records, root-only" "$out"
done
! grep -Fxq calibration "$fixture/calls" || fail "the M4 Max's calibration is resealed, never carved"
grep -Fxq 'options apple_sep xart_writes=1 provision_keybag=1 xart_guard=1' "$fixture/options-at-load" ||
  fail "the M4 Max's driver loads with the xART guard on, as Touch ID was tried there"
j616c
cp "$work/factory/j616c-other-chip.tar.gz" "$fixture/esp/asahi/all_firmware.tar.gz"
container=$work/factory/j616c-isc.img
! out=$(run touchid-enable 2>&1) && [[ $out == *"is not an M4 Max MacBook Pro's"* && ! -e $fixture/etc/touchid-on ]] &&
  [[ -z $(find "$fixture/firmware" -name '*j616c*') ]] ||
  fail "records sealed for the M4 Pro give an M4 Max nothing, and it says why" "$out"
unset container
mkdir -p "$fixture/firmware/updates/apple" "$fixture/etc"
cp "$work/factory/j616c-key.bin" "$fixture/firmware/updates/apple/msrk-j616c.bin"
cp "$work/factory/j616c-cal.bin" "$fixture/firmware/updates/apple/mesacal-j616c.bin"
touch "$fixture/etc/touchid-on"
PATH="$fixture/bin:$PATH" "$entry/disable-fingerprint" >/dev/null 2>&1 &&
  [[ ! -e $fixture/firmware/updates/apple/msrk-j616c.bin && ! -e $fixture/firmware/updates/apple/mesacal-j616c.bin &&
    ! -e $fixture/etc/touchid-on ]] ||
  fail "turning it off deletes an M4 Max's sensor key and calibration"
pass 'the 16-inch M4 Max rebuilds its calibration and sensor key from its own factory records'

if command -v systemd-analyze >/dev/null; then
  stub_systemd_boot_targets "$work/root"
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon flock install udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  for name in status load; do
    systemd-analyze --root="$work/root" verify --man=no "/usr/lib/systemd/system/omarchy-mac-touchid-$name.service" 2>"$work/verify" ||
      fail "systemd accepts the $name unit" "$(cat "$work/verify")"
  done
  pass 'systemd accepts the Touch ID status and load units'
fi
