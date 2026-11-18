#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
title="the fixture's title"

# Run one of base-test.sh's helpers in a child, so its fail() exits there.
run_in_child() {
  status=0
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT/test/base-test.sh" "$@" >"$tmp/out" 2>"$tmp/err" || status=$?
}

run_in_child fail "$title" $'the fixture\'s reason\nand its second line'
(( status == 1 )) || fail "a failing test exits 1" "$status"
[[ $(<"$tmp/err") == "not ok - $title"$'\nthe fixture\'s reason\nand its second line' ]] ||
  fail "a failing test prints its reason after its title" "$(cat "$tmp/err")"
[[ ! -s $tmp/out ]] || fail "a failing test prints nothing on stdout" "$(cat "$tmp/out")"

run_in_child fail "$title"
(( status == 1 )) || fail "a failing test without a reason exits 1" "$status"
[[ $(<"$tmp/err") == "not ok - $title" ]] || fail "a failing test without a reason prints only its title" "$(cat "$tmp/err")"

run_in_child pass "$title"
(( status == 0 )) || fail "a passing test exits 0" "$status"
[[ $(<"$tmp/out") == "ok - $title" && ! -s $tmp/err ]] || fail "a passing test prints only its title" "$(cat "$tmp/out" "$tmp/err")"

pass "a failing test prints the reason it gives"
