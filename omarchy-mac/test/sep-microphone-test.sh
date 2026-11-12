#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# An M1-family Mac records only zeros until its Secure Enclave boots, and the
# installed kernel's module has no alias, so the package boots it read-only at
# every boot, before the greeter, where the owner has not turned Touch ID on.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
unit=$units/omarchy-mac-sep-load.service
helper=$work/root/usr/lib/omarchy-mac/sep-for-microphone
[[ -f $unit && -x $helper && -L $units/multi-user.target.wants/omarchy-mac-sep-load.service &&
  $(readlink "$units/multi-user.target.wants/omarchy-mac-sep-load.service") == "../omarchy-mac-sep-load.service" ]] ||
  fail 'the unit and its helper are staged, and the unit is pulled in at boot without enabling'
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/sep-load' "$unit" && [[ -x $work/root/usr/lib/omarchy-mac/sep-load ]] ||
  fail 'the driver loads through the helper that keeps it read-only'
grep -Fq 'arguments+=("$option=0")' "$work/root/usr/lib/omarchy-mac/sep-load" ||
  fail 'the helper loads the driver read-only: it never writes the xART store shared with macOS and makes no keybag'
! grep -Eq 'xart_writes=1|provision_keybag=1' "$unit" "$helper" "$work/root/usr/lib/omarchy-mac/sep-load" ||
  fail 'nothing here turns the writes or the provisioning on'
grep -Eq '^After=.*\bomarchy-mac-touchid-status\.service\b' "$unit" ||
  fail 'the unit starts after the Touch ID status, which records whether the owner has agreed'
grep -Fxq 'ConditionPathExists=!/etc/omarchy-mac/touchid-on' "$unit" ||
  fail "once the owner has turned Touch ID on, its own load owns the driver"
grep -Fxq 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$unit" && grep -Fxq 'ExecCondition=/usr/lib/omarchy-mac/sep-for-microphone' "$unit" ||
  fail 'the unit runs only on an Apple Silicon Mac whose microphone needs the enclave'
grep -Fxq 'ExecStartPre=/usr/bin/udevadm wait --timeout=20 /dev/disk/by-partlabel/iBootSystemContainer' "$unit" ||
  fail "the driver loads after the iBoot System Container's link it opens as it probes"
! grep -Eq '^(Wants|Requires|BindsTo|After)=.*\.device' "$unit" ||
  fail 'the load waits for the link only once its conditions hold: a device dependency holds up every boot'
grep -Fxq 'Before=display-manager.service' "$unit" && grep -Fxq 'Type=oneshot' "$unit" && grep -Fxq 'TimeoutStartSec=30s' "$unit" ||
  fail "the enclave is up before the session's first capture, within a bounded time"
! grep -q '^\[Install\]' "$unit" || fail 'the unit needs no enabling: the wants link pulls it in'
pass 'the package boots the Secure Enclave read-only at boot, only while Touch ID is off'

# The helper reads only the device tree: an M1-family Mac whose tree enables
# its enclave needs it; later Macs, a tree that disables the node, a Mac
# without one and another platform do not.
fixture=$work/fixture
mkdir -p "$fixture/bin"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$fixture/bin/omarchy-hw-platform"
stub_apple_predicate "$fixture/bin"
chmod +x "$fixture/bin/"*
tree() {
  local root=$1 status=${3:-okay}
  rm -rf "$root"
  mkdir -p "$root/soc/sep@242400000"
  printf '%s\0' $2 >"$root/compatible"
  printf 'apple,sep\0' >"$root/soc/sep@242400000/compatible"
  if [[ $status != "none" ]]; then
    printf '%s\0' "$status" >"$root/soc/sep@242400000/status"
  fi
}
needs() {
  PATH="$fixture/bin:$PATH" OMARCHY_MAC_SEP_TREE=$fixture/tree "$ROOT/lib/sep-for-microphone"
}
for board in 'apple,j313 apple,t8103 apple,arm-platform' 'apple,j314s apple,t6000 apple,arm-platform' 'apple,j316c apple,t6001 apple,arm-platform'; do
  tree "$fixture/tree" "$board"
  needs || fail 'an M1-family Mac with its enclave enabled needs it' "$board"
  tree "$fixture/tree" "$board" none
  needs || fail 'a node without a status is enabled' "$board"
  tree "$fixture/tree" "$board" disabled
  ! needs || fail 'a tree that disables the enclave never loads its driver' "$board"
done
for board in 'apple,j413 apple,t8112 apple,arm-platform' 'apple,j414s apple,t6020 apple,arm-platform' 'apple,j613 apple,t8122 apple,arm-platform' 'apple,j700 apple,t8140 apple,arm-platform'; do
  tree "$fixture/tree" "$board"
  ! needs || fail 'a later Mac records without the enclave, so its driver stays unloaded' "$board"
done
tree "$fixture/tree" 'apple,j313 apple,t8103 apple,arm-platform'
rm -r "$fixture/tree/soc/sep@242400000"
! needs || fail 'a tree without an enclave node loads nothing'
tree "$fixture/tree" 'apple,j313 apple,t8103 apple,arm-platform'
! PLATFORM=x86_64 needs || fail 'the platform decides first'
status=0
PATH="$fixture/bin:$PATH" OMARCHY_MAC_SEP_TREE=$fixture/missing "$ROOT/lib/sep-for-microphone" || status=$?
(( status == 1 )) || fail 'without a device tree the unit is skipped, not failed' "$status"
pass 'only an M1-family Mac whose device tree enables its enclave boots it'

# The load passes each write option once as 0, and leaves alone what the owner
# set elsewhere: a second setting makes the driver refuse to load (EEXIST).
# Writes are never enabled; a driver already loaded is left as it is.
loader=$work/root/usr/lib/omarchy-mac/sep-load
mkdir -p "$fixture/loadbin"
cat >"$fixture/loadbin/modprobe" <<'STUB'
#!/bin/bash
if [[ ${1:-} == -c ]]; then
  # Like kmod: the configuration files first, then one options line per module
  # parameter word of the kernel command line (modprobe.* words are not options).
  cat "$FIXTURE_CONFIG"
  for word in $(<"$FIXTURE_CMDLINE"); do
    if [[ $word =~ ^([^.=]+)\.([^=]+=.*)$ && ${BASH_REMATCH[1]} != modprobe ]]; then
      echo "options ${BASH_REMATCH[1]//-/_} ${BASH_REMATCH[2]}"
    fi
  done
else
  echo "$*" >"$FIXTURE_CALL"
fi
STUB
chmod +x "$fixture/loadbin/modprobe"
load() {
  # $1 is modprobe's configuration, $2 the kernel command line, $3 "loaded" for a running driver
  printf '%s' "$1" >"$fixture/config"
  printf '%s\n' "$2" >"$fixture/cmdline"
  rm -rf "$fixture/sys" "$fixture/call"
  mkdir -p "$fixture/sys"
  if [[ ${3:-} == loaded ]]; then mkdir "$fixture/sys/apple_sep"; fi
  loaded_status=0
  PATH="$fixture/loadbin:$fixture/bin:$PATH" FIXTURE_CONFIG=$fixture/config FIXTURE_CMDLINE=$fixture/cmdline FIXTURE_CALL=$fixture/call \
    OMARCHY_MAC_SEP_SYSFS=$fixture/sys "$loader" >"$fixture/log" 2>&1 || loaded_status=$?
  loaded_call=$(cat "$fixture/call" 2>/dev/null || true)
  loaded_log=$(cat "$fixture/log")
}
load '' 'quiet splash'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep xart_writes=0 provision_keybag=0' ]] || fail 'with nothing set, the load passes both options as 0' "$loaded_call"
load $'options apple_sep xart_writes=0 provision_keybag=0\n' 'quiet'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep' ]] || fail 'options already at 0 elsewhere are used as they are, so a Mac nothing else loads still boots it' "$loaded_call"
load $'options apple-sep xart_writes=0\n' 'quiet'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep provision_keybag=0' ]] || fail 'only the option still missing is passed' "$loaded_call"
load '' 'quiet apple_sep.provision_keybag=0'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep xart_writes=0' ]] || fail 'an option on the kernel command line counts as set' "$loaded_call"
load $'options apple_sep xart_writes=0 provision_keybag=0\n' 'apple_sep.xart_writes=0'
[[ $loaded_status == 1 && -z $loaded_call ]] || fail 'the same option in modprobe.d and on the command line is listed twice, which fails with EEXIST: the unit says so instead of passing it on' "$loaded_status $loaded_call"
for conflict in $'options apple_sep xart_writes=1 provision_keybag=1\n' $'options apple_sep xart_writes=0 provision_keybag=1\n'; do
  load "$conflict" 'quiet'
  [[ $loaded_status == 0 && -z $loaded_call ]] || fail 'writes enabled elsewhere are left to their owner, and never loaded here' "$conflict $loaded_call"
done
load '' 'quiet apple_sep.xart_writes=1'
[[ $loaded_status == 0 && -z $loaded_call ]] || fail 'writes enabled on the command line are never loaded here' "$loaded_call"
# The kernel strips the quotes of a value, so a quoted zero is a zero.
load $'options apple_sep xart_writes="0"\n' 'quiet'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep provision_keybag=0' ]] || fail 'a quoted zero counts as zero' "$loaded_status $loaded_call"
load '' 'quiet apple_sep.provision_keybag="0"'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep xart_writes=0' ]] || fail 'a quoted zero on the command line counts as zero' "$loaded_status $loaded_call"
load $'options apple_sep xart_writes="1"\n' 'quiet'
[[ $loaded_status == 0 && -z $loaded_call ]] || fail 'a quoted one still enables writes and is left to its owner' "$loaded_status $loaded_call"
# Whenever the helper leaves the load to someone else or fails, it says the microphones stay silent.
[[ $loaded_log == *'microphones stay silent'* ]] || fail 'a skipped load says the built-in microphones stay silent' "$loaded_log"
load $'options apple_sep xart_writes=0\n' 'apple_sep.xart_writes=0'
[[ $loaded_status == 1 && $loaded_log == *'microphones stay silent'* ]] || fail 'a failed duplicate says the built-in microphones stay silent' "$loaded_log"
# The kernel treats - and _ in a parameter name alike.
load $'options apple_sep xart-writes=0\n' 'quiet'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep provision_keybag=0' ]] || fail 'a hyphenated option name counts as the underscored one, so it is not passed again' "$loaded_status $loaded_call"
load '' 'quiet apple_sep.provision-keybag=0'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep xart_writes=0' ]] || fail 'a hyphenated name on the command line counts as set' "$loaded_status $loaded_call"
load $'options apple_sep xart-writes=0\noptions apple_sep xart_writes=0\n' 'quiet'
[[ $loaded_status == 1 && -z $loaded_call ]] || fail 'the hyphenated and underscored names are one parameter, so both is a duplicate' "$loaded_status $loaded_call"
load $'options apple_sep provision-keybag=1\n' 'quiet'
[[ $loaded_status == 0 && -z $loaded_call ]] || fail 'a hyphenated name enabling a write is left to its owner' "$loaded_status $loaded_call"
load $'options apple_sep xart_writes=0 provision_keybag=0\n' 'quiet' loaded
[[ $loaded_status == 0 && -z $loaded_call ]] || fail 'a driver someone else loaded is left alone' "$loaded_call"
load $'options snd_soc_aop mic_check_123=1\noptions apple_sepx xart_writes=1\n' 'quiet snd.xart_writes=1'
[[ $loaded_status == 0 && $loaded_call == 'apple-sep xart_writes=0 provision_keybag=0' ]] || fail 'other modules options never count as the drivers' "$loaded_call"
pass 'the load passes each write option once as 0 and never enables a write'

# Verified inside the staged root, whose stub commands stand in for the
# runtime's platform check, so the result never depends on the host.
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$work/root/usr/bin"
  for command in omarchy-hw-apple-silicon udevadm; do
    printf '#!/bin/sh\nexit 0\n' >"$work/root/usr/bin/$command"
    chmod +x "$work/root/usr/bin/$command"
  done
  systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/omarchy-mac-sep-load.service 2>"$work/verify" ||
    fail 'systemd accepts the unit' "$(cat "$work/verify")"
  pass 'systemd accepts the Secure Enclave load unit'
fi
if command -v systemd-analyze >/dev/null && systemd-analyze condition --help >/dev/null 2>&1; then
  agreed=$work/condition/touchid-on
  mkdir -p "$work/condition"
  condition=$(grep '^ConditionPathExists=' "$unit")
  systemd-analyze condition "${condition//\/etc\/omarchy-mac\/touchid-on/$agreed}" >/dev/null 2>&1 ||
    fail 'a Mac whose owner has not turned Touch ID on runs the unit'
  touch "$agreed"
  ! systemd-analyze condition "${condition//\/etc\/omarchy-mac\/touchid-on/$agreed}" >/dev/null 2>&1 ||
    fail "a Mac whose owner turned Touch ID on leaves the driver to its own load"
  pass 'the unit yields to the Touch ID load once the owner has agreed'
fi
