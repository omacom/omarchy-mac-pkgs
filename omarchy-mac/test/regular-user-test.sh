#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
# EUID is read-only, so a copy of base-test.sh reads the user id from a variable.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed 's/EUID/TEST_EUID/g' "$ROOT/test/base-test.sh" >"$work/base-test.sh"
source_as() {
  status=0
  TEST_EUID=$1 bash -c 'source "$1"; echo sourced' _ "$work/base-test.sh" >"$work/out" 2>"$work/err" || status=$?
}

source_as 0
(( status == 1 )) || fail 'a suite run as root fails' "$(cat "$work/out" "$work/err")"
grep -q '^not ok - run the tests as a regular user' "$work/err" || fail 'the refusal says to run as a regular user' "$(cat "$work/err")"
[[ ! -s $work/out ]] || fail 'a suite run as root stops before its cases' "$(cat "$work/out")"

source_as 1000
(( status == 0 )) && [[ $(<"$work/out") == "sourced" && ! -s $work/err ]] ||
  fail 'a regular user runs the suite' "$(cat "$work/out" "$work/err")"

pass 'the suites refuse root, where the commands ignore fixture roots, and run as a regular user'
