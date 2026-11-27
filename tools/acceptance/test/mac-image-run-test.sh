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

expect_refusal "--mac needs a board" --image "$test_tmp" --mac
expect_refusal "--mac takes a device tree name like t6041-j614c, not j614c" --image "$test_tmp" --mac j614c
expect_refusal "this harness boots aarch64 guests" --image "$test_tmp" --mac t6041-j614c
pass "--mac takes a device tree name, and a valid one reaches the host checks"

# The guest's identity: the default Mac's, or the one --mac names, read from
# the image kernel's device tree for it. QEMU's dump is a stand-in tree.
require_command dtc
require_command fdtget
awk '/^make_apple_dtb\(\) \{/,/^}/' "$harness" >"$test_tmp/apple-dtb.sh"
compile_tree() { # output, dts body
  printf '/dts-v1/;\n/ {\n%s\n};\n' "$2" | dtc -q -I dts -O dtb -o "$1" - || fail "compiles the $1 fixture"
}
compile_tree "$test_tmp/virt.dtb" 'compatible = "linux,dummy-virt";'
compile_tree "$test_tmp/t6041-j614c.dtb" 'compatible = "apple,j614c", "apple,t6041", "apple,arm-platform"; model = "Apple MacBook Pro (14-inch, M4 Max, 2024)";'
compile_tree "$test_tmp/t6041-j999.dtb" 'compatible = "apple,j999", "apple,t6041";'
guest_identity() { # [board]
  rm -rf "$test_tmp/work"
  mkdir -p "$test_tmp/work"
  [[ -z ${1:-} ]] || cp "$test_tmp/$1.dtb" "$test_tmp/work/mac.dtb"
  (
    fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
    ok() { :; }
    qemu-system-aarch64() { cp "$test_tmp/virt.dtb" "${2##*dumpdtb=}"; }
    eval "$(grep -E '^apple_(compatible|model)=' "$harness")"
    # shellcheck disable=SC2034 # read by the sourced harness function
    work=$test_tmp/work machine=virt vm_memory_mb=1 vm_cpus=1 mac_board=${1:-}
    source "$test_tmp/apple-dtb.sh"
    make_apple_dtb
    printf '%s|%s\n' "$(fdtget -t s "$work/apple.dtb" / compatible)" "$(fdtget -t s "$work/apple.dtb" / model)"
  ) >"$test_tmp/out" 2>&1
}
guest_identity || fail "the default identity is set" "$(cat "$test_tmp/out")"
[[ $(cat "$test_tmp/out") == "apple,j314s apple,t6000 apple,arm-platform linux,dummy-virt|Apple MacBook Pro (14-inch, M1 Pro, 2021)" ]] ||
  fail "without --mac the guest is the M1 Pro" "$(cat "$test_tmp/out")"
guest_identity t6041-j614c || fail "the --mac identity is set" "$(cat "$test_tmp/out")"
[[ $(cat "$test_tmp/out") == "apple,j614c apple,t6041 apple,arm-platform linux,dummy-virt|Apple MacBook Pro (14-inch, M4 Max, 2024)" ]] ||
  fail "--mac t6041-j614c gives the guest the J614c's compatible and model" "$(cat "$test_tmp/out")"
! guest_identity t6041-j999 || fail "a board device tree without a model is refused"
grep -Fq 'the device tree for t6041-j999 has no root compatible and model' "$test_tmp/out" ||
  fail "names the board whose device tree lacks a model" "$(cat "$test_tmp/out")"
pass "the guest is the M1 Pro by default and the named board with --mac, from its own device tree"

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
  printf 'Press Return to Start Setup\n%sSelect keyboard layout\n%sUsername> \nPassword> \nConfirm> \n' "${language_step-}" "${timezone_step-}"
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

language_step=$'Language\n' console_log 'Hostname> ' 'Timezone' 'Does this look right?' 'omarchy login: ' >"$test_tmp/language.log"
: >"$test_tmp/sent"
run_owner_setup "$test_tmp/language.log" || fail "owner setup that asks for the language first finishes" "$(cat "$test_tmp/out")"
[[ $(grep -Fxc '\r|Language' "$test_tmp/sent") == 1 ]] || fail "owner setup keeps the default language once" "$(cat "$test_tmp/sent")"
[[ $(grep -Fxc '\r|Select keyboard layout' "$test_tmp/sent") == 1 ]] || fail "owner setup then keeps the default keyboard" "$(cat "$test_tmp/sent")"
pass "owner setup that asks for the language first keeps the default language and keyboard"

language_step=$'Language\n' timezone_step=$'Timezone\n' console_log 'Does this look right?' 'omarchy login: ' >"$test_tmp/account.log"
: >"$test_tmp/sent"
run_owner_setup "$test_tmp/account.log" || fail "owner setup that asks for the timezone first and no hostname finishes" "$(cat "$test_tmp/out")"
for prompt in Language 'Select keyboard layout' Timezone 'Does this look right?'; do
  [[ $(grep -Fxc "\\r|$prompt" "$test_tmp/sent") == 1 ]] || fail "owner setup keeps the default at $prompt once" "$(cat "$test_tmp/sent")"
done
grep -q 'Hostname\|Full name' "$test_tmp/sent" && fail "owner setup without a hostname prompt answers none" "$(cat "$test_tmp/sent")"
pass "owner setup that asks for the timezone first and generates the hostname keeps every default"

console_log 'Full name> ' 'Hostname> ' 'Timezone' 'Does this look right?' 'omarchy login: ' >"$test_tmp/broken.log"
: >"$test_tmp/sent"
! run_owner_setup "$test_tmp/broken.log" || fail "owner setup with a full name but no email fails"
grep -Fq 'Email address> ' "$test_tmp/out" || fail "owner setup names the missing Email address> prompt" "$(cat "$test_tmp/out")"
pass "owner setup that asks for a full name but no email fails on the missing prompt"
