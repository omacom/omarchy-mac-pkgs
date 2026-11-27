#!/bin/bash
# The configuration transition reads this report. It must be the diag values,
# and it must not open the node: opening /dev/sep-bio activates Touch ID.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
report=$work/root/usr/lib/omarchy-mac/touchid-recovery
[[ -x $report && $(stat -c %a "$report") == 755 ]] || fail 'the readiness report is installed executable'
cmp -s "$ROOT/lib/touchid-recovery" "$report" || fail 'install ships the report unchanged'
pass 'omarchy-mac installs the Touch ID readiness report'

fixture=$work/fixture
driver=$fixture/apple_sep
node=$fixture/sep-bio
mkdir -p "$fixture/bin"
printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/omarchy-hw-apple-silicon"
chmod +x "$fixture/bin/omarchy-hw-apple-silicon"

write_diag() {
  local directory=$1
  shift
  mkdir -p "$directory"
  local name value
  while [[ $# -ge 2 ]]; do
    name=$1
    value=$2
    printf '%s\n' "$value" >"$directory/$name"
    shift 2
  done
}

run_report() {
  PATH="$fixture/bin:$PATH" \
    OMARCHY_MAC_TOUCHID_NODE=$node \
    OMARCHY_MAC_TOUCHID_DRIVER=$driver \
    "$ROOT/lib/touchid-recovery"
}

parse() {
  python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, sort_keys=True); sys.stdout.write("\n")'
}

ready_diag() {
  write_diag "$1" \
    keystore open keybag present host_store ready xart enabled sensor online touchid ready \
    sensor_attach attached restore restored matching usable xart_guard_refusals 0
}

rm -rf "$driver"
mkdir -p "$driver"
ready_diag "$driver/a.sep/diag"
touch "$node"
got=$(run_report | parse)
want=$(printf '%s\n' '{"action":"ready-for-test","facts":{"keystore":"open","keybag":"present","host_store":"ready","matching":"usable","refusals":0,"restore":"restored","sensor":"online","sensor_attach":"attached","touchid":"ready","xart":"enabled"},"node_present":true}' | parse)
[[ $got == "$want" ]] || fail 'a restored, usable sensor is ready for the transition' "$got"
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert type(report["facts"]["refusals"]) is int and report["facts"]["refusals"] == 0' "$got" ||
  fail 'refusals is a number, so the transition can match 0'
pass 'the report is ready only from the diag attributes the transition requires'

# A later device must not hide the first one the driver directory names.
ready_diag "$driver/b.sep/diag"
printf 'failed\n' >"$driver/b.sep/diag/touchid"
got=$(run_report | parse)
[[ $got == "$want" ]] || fail 'a later device does not hide the first ready report' "$got"
printf 'failed\n' >"$driver/a.sep/diag/touchid"
printf 'ready\n' >"$driver/b.sep/diag/touchid"
got=$(run_report)
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["action"] == "unsupported"' "$got" ||
  fail 'the first device is the report, even when a later one is ready' "$got"
pass 'the first bound device is the report, and a later one neither hides nor replaces it'
printf 'ready\n' >"$driver/a.sep/diag/touchid"
rm "$driver/a.sep/diag/host_store"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["host_store"] == "missing"' "$got" ||
  fail 'a later device cannot supply a missing host-store fact for the first' "$got"
pass 'facts are not mixed across bound devices'

rm -rf "$driver"
mkdir -p "$driver/a.sep/diag"
ready_diag "$driver/a.sep/diag"
printf 'empty\n' >"$driver/a.sep/diag/restore"
printf 'unverified\n' >"$driver/a.sep/diag/matching"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "ready-for-test" and report["facts"]["restore"] == "empty" and report["facts"]["matching"] == "unverified"' "$got" ||
  fail 'nothing enrolled, behind a guard that has refused nothing, stays ready for a trial' "$got"
for value in failed unavailable missing read-only invalid; do
  printf '%s\n' "$value" >"$driver/a.sep/diag/host_store"
  got=$(run_report)
  python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["host_store"] == sys.argv[2]' "$got" "$value" ||
    fail 'an open keystore cannot hide a host-store failure' "$got"
done
rm "$driver/a.sep/diag/host_store"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["host_store"] == "missing"' "$got" ||
  fail 'a kernel without the host-store diagnostic cannot claim readiness' "$got"
printf 'ready\n' >"$driver/a.sep/diag/host_store"
pass 'actual host-store failures and missing diagnostics fail closed'
printf 'closed\n' >"$driver/a.sep/diag/keystore"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["keystore"] == "closed"' "$got" ||
  fail 'a closed key store is not a ready host store' "$got"
printf 'open\n' >"$driver/a.sep/diag/keystore"
printf 'missing\n' >"$driver/a.sep/diag/keybag"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["keybag"] == "missing"' "$got" ||
  fail 'an open key store without an identity keybag is not ready' "$got"
printf 'present\n' >"$driver/a.sep/diag/keybag"
printf '2\n' >"$driver/a.sep/diag/xart_guard_refusals"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["refusals"] == 2' "$got" ||
  fail 'guard refusals keep the report from ready-for-test' "$got"
rm "$driver/a.sep/diag/xart_guard_refusals"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "unsupported" and report["facts"]["refusals"] == -1' "$got" ||
  fail 'a missing refusal count is not reported as zero' "$got"
pass 'keybag, key store and refusals each keep a nearly ready sensor off ready-for-test'

rm -rf "$driver"
mkdir -p "$driver/a.sep/diag"
printf 'unknown\n' >"$driver/a.sep/diag/touchid"
rm -f "$node"
got=$(run_report)
python3 -c 'import json,sys; report=json.loads(sys.argv[1]); assert report["action"] == "setup" and report["node_present"] is False' "$got" ||
  fail 'a sensor that has not been activated is setup, with no node' "$got"
ln -s missing "$node"
got=$(run_report)
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["node_present"] is False' "$got" ||
  fail 'a symlink is not treated as the node' "$got"
rm "$node"
mkfifo "$node"
if ! timeout 2 env PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_NODE=$node OMARCHY_MAC_TOUCHID_DRIVER=$driver \
  "$ROOT/lib/touchid-recovery" >"$fixture/out"; then
  fail 'the report opened the node; opening it would activate Touch ID'
fi
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["node_present"] is True' "$fixture/out" ||
  fail 'a node that exists is present without being opened'
pass 'the report never opens the node'

printf '#!/bin/sh\nexit 1\n' >"$fixture/bin/omarchy-hw-apple-silicon"
mkdir -p "$fixture/canary"
out=$(PATH="$fixture/bin:$PATH" OMARCHY_MAC_TOUCHID_NODE=$fixture/canary/node OMARCHY_MAC_TOUCHID_DRIVER=$fixture/canary \
  "$ROOT/lib/touchid-recovery")
[[ -z $out && -z $(find "$fixture/canary" -mindepth 1 -print -quit) ]] ||
  fail 'off Apple Silicon the report prints nothing and writes nothing' "$out"
pass 'off Apple Silicon the report stops before reading the driver'
