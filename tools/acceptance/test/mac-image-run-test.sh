#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

harness="$ROOT/tools/acceptance/mac-image/run"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
unset "${!OMARCHY_VM_@}"

# A host that is not an aarch64 KVM host: a run that gets past its arguments
# stops at the first host check.
mkdir -p "$test_tmp/bin"
printf '#!/bin/bash\necho x86_64\n' >"$test_tmp/bin/uname"
chmod +x "$test_tmp/bin/uname"

run_harness() {
  PATH="$test_tmp/bin:$PATH" HOME="$test_tmp/home" bash "$harness" "$@" >"$test_tmp/out" 2>&1
}

scenarios=(first-boot conversion second-boot password-change update snapshot-restore factory-reset)

run_harness --list || fail "--list succeeds" "$(cat "$test_tmp/out")"
for name in "${scenarios[@]}" fresh-install all; do
  grep -Eq "^$name +[^ ]" "$test_tmp/out" || fail "--list names $name" "$(cat "$test_tmp/out")"
done
[[ ! -e $test_tmp/home ]] || fail "--list touches no state"
pass "--list names every scenario and the fresh-install and all sets without touching state"

for name in "${scenarios[@]}"; do
  grep -Eq "^scenario_${name//-/_}\(\) \{" "$harness" || fail "$name has a scenario function"
done
pass "every listed scenario has its own function"

expect_refusal() {
  local message=$1
  shift
  ! run_harness "$@" || fail "refuses: $*"
  grep -Fq -- "$message" "$test_tmp/out" || fail "refuses $* with: $message" "$(cat "$test_tmp/out")"
}

expect_refusal "Unknown scenario: reboot" --image "$test_tmp" --scenario first-boot,reboot
expect_refusal "give --image DIR or --payload ZIP" --scenario first-boot
expect_refusal "--image and --payload are exclusive" --image "$test_tmp" --payload "$test_tmp/p.zip"
expect_refusal "--lane is read from IMAGE with --image" --image "$test_tmp" --lane rc
expect_refusal "--scenario needs a name" --image "$test_tmp" --scenario
expect_refusal "Unknown option: --release" --release mac-image-10-rc
OMARCHY_VM_RUN_ID="../x" expect_refusal "OMARCHY_VM_RUN_ID must be" --image "$test_tmp"
pass "bad scenarios, inputs and run IDs are refused before the host is checked"

for selection in fresh-install all "update,snapshot-restore" second-boot; do
  expect_refusal "this harness boots aarch64 guests" --image "$test_tmp" --scenario "$selection"
done
[[ ! -e $test_tmp/home ]] || fail "a refused host keeps no state"
pass "valid selections reach the host checks, and a refused host keeps no state"

# The cases that wait for an entrypoint probe the paths their skip reasons name.
for path in /usr/lib/omarchy/mac-boot/update-verify /etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check /usr/lib/omarchy/mac-boot/reset-prepare; do
  [[ $(grep -Fc -- "$path" "$harness") -ge 2 ]] || fail "$path is both probed and named in its skip reason"
done
pass "each entrypoint case probes the path its skip reason names"

# Owner setup over a recorded console: the harness's own serial functions read
# a log written in advance, and the guest has already exited, so a prompt that
# never comes fails at once instead of after its timeout.
awk '/^(serial_find|serial_expect|owner_setup)\(\) \{/,/^}/' "$harness" >"$test_tmp/owner-setup.sh"
run_owner_setup() {
  (
    fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
    boot_writable() { :; }
    serial_send() { printf '%s|%s\n' "${1//$'\r'/\\r}" "$serial_match" >>"$test_tmp/sent"; }
    serial_type() { serial_send "$1"$'\r'; }
    # shellcheck disable=SC2034 # read by the sourced harness functions
    owner_user=owner owner_password=secret boot_timeout=1 serial_log=$1 serial_pos=0 serial_match=
    sleep 0 & qemu_pid=$!; wait "$qemu_pid"
    source "$test_tmp/owner-setup.sh"
    owner_setup test
  ) >"$test_tmp/out" 2>&1
}
console_log() {
  printf 'Press Return to Start Setup\nSelect keyboard layout\nUsername> \nPassword> \nConfirm> \n'
  local prompt
  for prompt in "$@"; do printf '%s\n' "$prompt"; done
}

console_log 'Hostname> ' 'Timezone' 'Does this look right?' 'omarchy login: ' >"$test_tmp/new.log"
: >"$test_tmp/sent"
run_owner_setup "$test_tmp/new.log" || fail "owner setup without the git identity prompts finishes" "$(cat "$test_tmp/out")"
grep -q 'Full name\|Email address' "$test_tmp/sent" && fail "owner setup without the git identity prompts answers none" "$(cat "$test_tmp/sent")"
[[ $(grep -Fxc '\r|Hostname> ' "$test_tmp/sent") == 1 ]] || fail "owner setup keeps the default hostname" "$(cat "$test_tmp/sent")"
pass "owner setup without the git identity prompts keeps every default"

console_log 'Full name> ' 'Email address> ' 'Hostname> ' 'Timezone' 'Does this look right?' 'omarchy login: ' >"$test_tmp/old.log"
: >"$test_tmp/sent"
run_owner_setup "$test_tmp/old.log" || fail "owner setup with the git identity prompts finishes" "$(cat "$test_tmp/out")"
for prompt in 'Full name> ' 'Email address> ' 'Hostname> '; do
  [[ $(grep -Fxc "\\r|$prompt" "$test_tmp/sent") == 1 ]] || fail "owner setup skips $prompt once" "$(cat "$test_tmp/sent")"
done
pass "owner setup with the git identity prompts skips name and email and keeps the default hostname"

console_log 'Full name> ' 'Hostname> ' 'Timezone' 'Does this look right?' 'omarchy login: ' >"$test_tmp/broken.log"
: >"$test_tmp/sent"
! run_owner_setup "$test_tmp/broken.log" || fail "owner setup with a full name but no email fails"
grep -Fq 'Email address> ' "$test_tmp/out" || fail "owner setup names the missing Email address> prompt" "$(cat "$test_tmp/out")"
pass "owner setup that asks for a full name but no email fails on the missing prompt"
