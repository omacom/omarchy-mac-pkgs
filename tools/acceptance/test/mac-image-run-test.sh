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

# The scenarios that drive an omarchy-mac-boot entrypoint or boot hook probe its path.
entrypoints=(update:/usr/lib/omarchy/mac-boot/update-verify snapshot-restore:/etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check factory-reset:/usr/lib/omarchy/mac-boot/reset-prepare)
for entry in "${entrypoints[@]}"; do
  grep -Fq -- "$entry" "$harness" || fail "the image probe keys ${entry%%:*} to ${entry#*:}"
done
pass "the image probe keys each entrypoint scenario to its path"

# The harness's own result helpers and entrypoint scenarios, stopped at the
# conversion they need, so a scenario that gets past its entrypoint check boots nothing.
{
  grep -E '^(record|not_ok|ok|skip)\(\) \{' "$harness"
  awk '/^scenario_(update|snapshot_restore|factory_reset)\(\) \{/,/^}/' "$harness"
} >"$test_tmp/entrypoint-scenarios.sh"
run_entrypoint_scenario() {
  rm -rf "$test_tmp/evidence"
  mkdir -p "$test_tmp/evidence"
  # shellcheck disable=SC2034 # read by the sourced harness functions
  (
    declare -A image_ships=()
    [[ -z $2 ]] || image_ships[$1]=$2
    evidence_dir=$test_tmp/evidence checks_failed=0
    need_conversion() { echo "need_conversion $1" >>"$evidence_dir/run.txt"; exit 0; }
    source "$test_tmp/entrypoint-scenarios.sh"
    "scenario_${1//-/_}"
    echo "checks_failed=$checks_failed" >>"$evidence_dir/run.txt"
  ) >"$test_tmp/out" 2>&1
}

log=$test_tmp/evidence/run.txt
for entry in "${entrypoints[@]}"; do
  name=${entry%%:*} path=${entry#*:}
  run_entrypoint_scenario "$name" "" || fail "$name without its entrypoint returns to the run" "$(cat "$test_tmp/out")"
  grep -Eq "^not ok - $name: .*${path//./\\.}" "$log" || fail "$name without $path records not ok naming it" "$(cat "$log")"
  ! grep -q '^skip - ' "$log" || fail "$name without $path records no skip" "$(cat "$log")"
  grep -Fxq 'checks_failed=1' "$log" || fail "$name without $path fails the run" "$(cat "$log")"
  ! grep -q '^need_conversion' "$log" || fail "$name without $path boots nothing" "$(cat "$log")"

  run_entrypoint_scenario "$name" "$path" || fail "$name with its entrypoint reaches its conversion" "$(cat "$test_tmp/out")"
  grep -Fxq "need_conversion $name" "$log" || fail "$name with $path goes on to its conversion" "$(cat "$log")"
  ! grep -Eq '^(not ok|skip) - ' "$log" || fail "$name with $path records no failure or skip" "$(cat "$log")"
done
pass "a selected scenario fails the run when the image lacks its entrypoint, and runs when it has it"

# The probe reads the image root, never the host, even through an absolute link
# such as the snapshot check hook's; sudo runs the real test and readlink.
grep -Fq '! image_has "$lower" "${path#*:}"' "$harness" || fail "the image probe goes through image_has"
awk '/^image_has\(\) \{/,/^}/' "$harness" >"$test_tmp/image-has.sh"
image_has_in_fixture() {
  (
    sudo() { [[ $1 != -n ]] || shift; "$@"; }
    source "$test_tmp/image-has.sh"
    image_has "$test_tmp/image" "$1"
  )
}
mkdir -p "$test_tmp/image/usr/bin" "$test_tmp/image/usr/lib/omarchy/mac-boot" "$test_tmp/image/etc/boot/hooks/pre.d"
: >"$test_tmp/image/usr/bin/omarchy-mac-snapshot-check"
: >"$test_tmp/image/usr/lib/omarchy/mac-boot/update-verify"
ln -s /usr/bin/omarchy-mac-snapshot-check "$test_tmp/image/etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check"
ln -s /usr/bin/env "$test_tmp/image/etc/boot/hooks/pre.d/host-only"
ln -s ../../../../usr/bin/omarchy-mac-snapshot-check "$test_tmp/image/etc/boot/hooks/pre.d/relative"
ln -s missing "$test_tmp/image/etc/boot/hooks/pre.d/dangling"
for path in /usr/lib/omarchy/mac-boot/update-verify /etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check /etc/boot/hooks/pre.d/relative; do
  image_has_in_fixture "$path" || fail "the image has $path"
done
for path in /usr/lib/omarchy/mac-boot/reset-prepare /etc/boot/hooks/pre.d/host-only /etc/boot/hooks/pre.d/dangling; do
  ! image_has_in_fixture "$path" || fail "the image lacks $path"
done
pass "the image probe finds files and links that resolve inside the image, and nothing only the host has"

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
