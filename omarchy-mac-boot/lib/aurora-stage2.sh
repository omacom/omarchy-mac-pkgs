# shellcheck shell=bash
# shellcheck disable=SC2154 # root, workdir, esp and the rest are the check's
# Sourced by omarchy-apple-silicon-boot-check: Stage 2 where /usr/bin/update-m1n1
# is Aurora's, asked of its bootchain.py through aurora-stage2.py, never by
# running update-m1n1. The package README's "Aurora's Stage 2" explains it.

# True when UPDATE_M1N1 is Aurora's wrapper around bootchain.py.
aurora_update_m1n1() {
  grep -Fq 'AURORA_BOOTCHAIN' "$1"
}

# The wrapper's defaults, NAME=VALUE with $SOURCE left in. Fails unless each is
# there once in a form this reads, and the wrapper has the steps this relies on.
aurora_wrapper_defaults() {
  local script=$1 line name value step
  local quoted_default='^:[[:space:]]+"\$\{([A-Z0-9_]+):=([^}]*)\}"[[:space:]]*$'
  local exported_default='^export[[:space:]]+([A-Z0-9_]+)=\$\{([A-Z0-9_]+):-(.*)\}[[:space:]]*$'
  local -A seen=()
  # shellcheck disable=SC2016 # literal lines of the wrapper
  for step in '[[ ! -f /etc/default/update-m1n1 ]] || source /etc/default/update-m1n1' \
    '[[ -z ${M1N1_UPDATE_DISABLED:-} ]] || exit 0' \
    '[[ -z ${DTBS+x} ]] || export DTBS' \
    'python3 "$AURORA_BOOTCHAIN" --check || exit 1'; do
    grep -Fq -- "$step" "$script" ||
      fail "/usr/bin/update-m1n1 is Aurora's, but does not build Stage 2 the way this check reproduces it"
  done
  while IFS= read -r line; do
    if [[ $line =~ $quoted_default ]]; then
      name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    elif [[ $line =~ $exported_default && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then
      name=${BASH_REMATCH[1]} value=${BASH_REMATCH[3]}
    else
      continue
    fi
    case "$name" in
      SOURCE | M1N1 | U_BOOT | CONFIG | AURORA_DEVICE_TREE_COMPATIBLE | AURORA_MONITOR_FREE_MARKER | AURORA_BOOTCHAIN) ;;
      *) continue ;;
    esac
    [[ -z ${seen[$name]:-} ]] || fail "Aurora's /usr/bin/update-m1n1 sets a $name default twice"
    seen[$name]=1
    printf '%s=%s\n' "$name" "$value"
  done <"$script"
  for name in SOURCE M1N1 U_BOOT CONFIG AURORA_DEVICE_TREE_COMPATIBLE AURORA_MONITOR_FREE_MARKER AURORA_BOOTCHAIN; do
    [[ -n ${seen[$name]:-} ]] || fail "Aurora's /usr/bin/update-m1n1 has no $name default this check recognises"
  done
}

# One line of /proc/device-tree/chosen, without its terminating NUL.
aurora_chosen() {
  local node
  node=$(path "/proc/device-tree/chosen/$1")
  [[ ! -r $node ]] || tr -d '\0' <"$node"
}

# aurora-stage2.py MODE ARGUMENT..., as root with the environment the wrapper
# exports (aurora_environment), as update-m1n1 itself runs.
aurora_ask() {
  local mode=$1 search=/usr/bin:/bin
  shift
  # A test root's stubs come from the caller's PATH; a live check uses root's own.
  [[ -z $root ]] || search=$PATH
  sudo env -i PATH="$search" "${aurora_environment[@]}" python3 -I -B "$aurora_helper" "$mode" "${root:-/}" "$root$aurora_bootchain" "$@"
}

# What to do about a live Stage 2 that is not the current build, given what
# update-m1n1 would do: refuse beside another aura-try, skip an image it tried.
aurora_remedy() {
  local answer record
  if [[ -n $aurora_foreign_marker ]]; then
    printf '%s' "update-m1n1 stages no trial while aura-try on the system ESP names $aurora_foreign_marker; deal with that trial first"
    return 0
  fi
  answer=$(aurora_ask attempt "$aurora_sha" 2>/dev/null) || answer=""
  if [[ $answer == *"recorded=tried"* ]]; then
    record=$(sed -n 's/^record=//p' <<<"$answer")
    printf '%s' "update-m1n1 has already tried this image (${record#"$root"}) and does not arm it again; find out why that trial did not commit"
  else
    printf '%s' "run sudo update-m1n1, then omarchy update"
  fi
}

# Fails unless the trial candidate (ESP-relative RELATIVE) is the image just
# built and has the receipt and attempt record aurora-stage2-commit requires.
aurora_trial_matches() {
  local candidate=$1 relative=$2 state=$3 built=$workdir/aurora-stage2.bin answer
  sudo test -f "$candidate" ||
    fail "the $state Stage 2 trial names $relative, which is not on the system ESP ($esp)"
  sudo cmp -s "$built" "$candidate" ||
    fail "the $state Stage 2 trial $relative on the system ESP ($esp) is not what Aurora's update-m1n1 builds now from aura, $kernel $kver's device trees, U-Boot and its configuration; it is a stale trial"
  # shellcheck disable=SC2024 # the copy is the check's own
  sudo cat "$candidate.json" >"$workdir/aurora-receipt" 2>/dev/null &&
    grep -Fq "\"sha256\": \"$aurora_sha\"" "$workdir/aurora-receipt" &&
    grep -Fq "\"path\": \"$relative\"" "$workdir/aurora-receipt" ||
    fail "the $state Stage 2 trial $relative has no receipt for it on the system ESP ($esp), so aurora-stage2-commit would not commit it"
  answer=$(aurora_ask attempt "$aurora_sha" "$workdir/aurora-receipt" 2>/dev/null) || answer=""
  [[ $answer == *"matches=yes"* ]] ||
    fail "the $state Stage 2 trial $relative has no matching attempt record in /var/lib/aurora-stage2/attempts, so aurora-stage2-commit would not commit it"
}

# The Stage 2 check on a Mac whose update-m1n1 is Aurora's. Returns once the
# next boot reads what update-m1n1 builds now; fails otherwise.
aurora_check_stage2() {
  local script=$1 entry name value config_file built=$workdir/aurora-stage2.bin plan stage2 selected
  local SOURCE M1N1 U_BOOT CONFIG DTBS AURORA_DEVICE_TREE_COMPATIBLE AURORA_MONITOR_FREE_MARKER AURORA_BOOTCHAIN
  local dtbs_set="" disabled="" m1n1_file root_real m1n1_configured
  local -a defaults=() overlays=()
  aurora_wrapper_defaults "$script" >"$workdir/aurora-defaults"
  mapfile -t defaults <"$workdir/aurora-defaults"

  # The wrapper's configuration, read in a clean shell. The overlays stay off:
  # they follow only the stock update-m1n1's DTBS default.
  SOURCE="" M1N1="" U_BOOT="" CONFIG="" DTBS="" AURORA_DEVICE_TREE_COMPATIBLE="" AURORA_MONITOR_FREE_MARKER="" AURORA_BOOTCHAIN=""
  config_file=$(path /etc/default/update-m1n1)
  if [[ -e $config_file ]]; then
    env -i PATH=/usr/bin:/bin OMARCHY_DTB_OVERLAYS=0 bash --noprofile --norc -c '
      unset DTBS SOURCE M1N1 U_BOOT CONFIG AURORA_DEVICE_TREE_COMPATIBLE AURORA_MONITOR_FREE_MARKER AURORA_BOOTCHAIN M1N1_UPDATE_DISABLED
      . "$1" >/dev/null 2>&1 || exit 1
      for name in SOURCE M1N1 U_BOOT CONFIG AURORA_DEVICE_TREE_COMPATIBLE AURORA_MONITOR_FREE_MARKER AURORA_BOOTCHAIN M1N1_UPDATE_DISABLED; do
        printf "%s=%s\0" "$name" "${!name-}"
      done
      [[ -z ${DTBS+x} ]] || printf "DTBS_SET=1\0DTBS=%s\0" "$DTBS"
    ' _ "$config_file" >"$workdir/aurora-config" || fail "/etc/default/update-m1n1 cannot be read"
    while IFS= read -r -d '' entry; do
      value=${entry#*=}
      case "${entry%%=*}" in
        SOURCE) SOURCE=$value ;;
        M1N1) M1N1=$value ;;
        U_BOOT) U_BOOT=$value ;;
        CONFIG) CONFIG=$value ;;
        AURORA_DEVICE_TREE_COMPATIBLE) AURORA_DEVICE_TREE_COMPATIBLE=$value ;;
        AURORA_MONITOR_FREE_MARKER) AURORA_MONITOR_FREE_MARKER=$value ;;
        AURORA_BOOTCHAIN) AURORA_BOOTCHAIN=$value ;;
        M1N1_UPDATE_DISABLED) disabled=$value ;;
        DTBS_SET) dtbs_set=1 ;;
        DTBS) DTBS=$value ;;
      esac
    done <"$workdir/aurora-config"
  fi
  # The wrapper exits before anything else, the boot-time commit and guard included.
  [[ -z $disabled ]] ||
    fail "M1N1_UPDATE_DISABLED is set in /etc/default/update-m1n1, so Aurora's update-m1n1 neither rebuilds Stage 2 nor commits or guards its trials, and Stage 2 cannot be vouched for; once Stage 2 may follow the packages again, remove it, run sudo update-m1n1, then omarchy update"
  m1n1_configured=$M1N1

  # The wrapper's defaults fill what the configuration leaves unset or empty,
  # SOURCE first, since the M1N1 and U_BOOT defaults name it.
  mapfile -t defaults < <(printf '%s\n' "${defaults[@]}" | grep '^SOURCE='; printf '%s\n' "${defaults[@]}" | grep -v '^SOURCE=')
  for entry in "${defaults[@]}"; do
    name=${entry%%=*}
    value=${entry#*=}
    [[ -z ${!name} ]] || continue
    [[ ! $value =~ ^\"(.*)\"$ ]] || value=${BASH_REMATCH[1]}
    [[ $value != '$SOURCE/'* ]] || value=$SOURCE/${value#'$SOURCE/'}
    [[ $value =~ ^/[A-Za-z0-9._/+,-]*$ ]] ||
      fail "Aurora's /usr/bin/update-m1n1 has a $name default this check does not recognise: ${entry#*=}"
    printf -v "$name" '%s' "$value"
  done

  for name in M1N1 U_BOOT; do
    [[ -f $root${!name} ]] || fail "$name ${!name} does not exist"
  done
  [[ -f $root$AURORA_BOOTCHAIN ]] || fail "Aurora's update-m1n1 builds Stage 2 with $AURORA_BOOTCHAIN, which is not installed"
  command -v python3 >/dev/null 2>&1 || fail "python3 is not installed, and Aurora's update-m1n1 needs it"
  m1n1_file=$(realpath -e "$root$M1N1")
  root_real=$(realpath -m "${root:-/}")
  [[ $root_real == / ]] || m1n1_file=${m1n1_file#"$root_real"}
  if grep -Fxq -- "$m1n1_file" "$workdir/bootloader-files"; then
    :
  elif [[ -n $m1n1_configured ]]; then
    echo "Apple Silicon boot check: Stage 2 is built from M1N1=$M1N1, which /etc/default/update-m1n1 names and $bootloader does not install; it is checked as configured"
  else
    fail "M1N1 $M1N1 is not owned by $bootloader"
  fi
  export OMARCHY_DTB_OVERLAYS_ROOT=$root
  mapfile -t overlays < <(dtb_overlays_list)
  (( ${#overlays[@]} == 0 )) ||
    echo "Apple Silicon boot check: warning: device tree overlays are installed, but Aurora's update-m1n1 leaves them out of Stage 2" >&2

  # bootchain.py's plan, given what the wrapper would export.
  aurora_helper=$(dirname -- "$(realpath -- "$0")")/../lib/omarchy-mac/boot/aurora-stage2.py
  [[ -r $aurora_helper ]] || aurora_helper=$(dirname -- "$(realpath -- "$0")")/../lib/aurora-stage2.py
  aurora_bootchain=$AURORA_BOOTCHAIN
  aurora_environment=(M1N1="$M1N1" U_BOOT="$U_BOOT" CONFIG="$CONFIG"
    AURORA_DEVICE_TREE_COMPATIBLE="$AURORA_DEVICE_TREE_COMPATIBLE" AURORA_MONITOR_FREE_MARKER="$AURORA_MONITOR_FREE_MARKER"
    AURORA_KERNEL_ACTION=refresh AURORA_KERNEL_VERSION= TARGET=/m1n1/boot.bin)
  [[ -z $dtbs_set ]] || aurora_environment+=(DTBS="$DTBS")
  # Created here, so the image root writes stays the check's to read and remove.
  : >"$built"
  plan=$(aurora_ask plan "$built" 2>"$workdir/aurora-plan.err") ||
    fail "Aurora's update-m1n1 would not build Stage 2: $(tail -n 1 "$workdir/aurora-plan.err")"
  stage2=$(sed -n 's/^target=//p' <<<"$plan")
  selected=$(sed -n 's/^kernel=//p' <<<"$plan")
  [[ $stage2 == "boot.bin" || $stage2 == "boot-ctxr.bin" ]] ||
    fail "Aurora's update-m1n1 would write Stage 2 to ${stage2:-no file}, which this check does not know"
  stage2=m1n1/$stage2
  [[ $selected == "$kver" ]] ||
    fail "Aurora's update-m1n1 builds Stage 2 with kernel ${selected:-unknown}'s device trees, not $kernel $kver's"
  aurora_sha=$(sha256sum <"$built")
  aurora_sha=${aurora_sha%% *}

  mount_system_esp
  sudo test -f "$mountpoint/$stage2" || fail "the system ESP ($esp) has no $stage2"
  [[ $stage2 != "m1n1/boot.bin" ]] || ! sudo test -f "$mountpoint/m1n1/boot-ctxr.bin" ||
    echo "Apple Silicon boot check: warning: Aurora's update-m1n1 targets $stage2, so this check did not compare m1n1/boot-ctxr.bin on the system ESP ($esp); a Stage 1 that boots m1n1/boot-ctxr.bin is not covered" >&2
  limine_on_system_esp
  if [[ ${OMARCHY_BOOT_CHECK_ROLLBACK_ESP:-0} == 1 ]]; then
    echo "Apple Silicon boot check: $stage2 and Limine on the system ESP are the ones that booted this snapshot"
  else
    aurora_check_trial "$stage2"
  fi
}

# The live Stage 2 and any trial of it on the mounted ESP, against the image
# just built. Returns when the next boot reads that image, or a trial of it
# that falls back to the live one; fails otherwise.
aurora_check_trial() {
  local stage2=$1 live=$mountpoint/$1 relative=$1.next marker=$mountpoint/aura-try
  local built=$workdir/aurora-stage2.bin live_matches=0 state="" named="" answer trial
  aurora_foreign_marker=""
  sudo cmp -s "$built" "$live" && live_matches=1
  if sudo test -e "$marker"; then
    # shellcheck disable=SC2024 # the copy is the check's own
    sudo cat "$marker" >"$workdir/aura-try" || fail "cannot read aura-try on the system ESP ($esp)"
    answer=$(aurora_ask marker "$workdir/aura-try" 2>/dev/null) ||
      fail "aura-try on the system ESP ($esp) is not a marker Aurora's update-m1n1 recognises"
    state=$(sed -n 's/^state=//p' <<<"$answer")
    named=$(sed -n 's/^path=//p' <<<"$answer")
  fi
  trial=$(aurora_chosen aurora,trial)

  if [[ $state == "armed" ]]; then
    [[ $named == "$relative" ]] ||
      fail "aura-try on the system ESP ($esp) arms $named, a trial Aurora's update-m1n1 did not stage for $stage2, so the next boot tries an image this check cannot vouch for"
    aurora_trial_matches "$live.next" "$relative" armed
    echo "Apple Silicon boot check: a Stage 2 trial is armed: the next boot tries $relative, what Aurora's update-m1n1 builds now, once, and keeps $stage2 to fall back to"
    return 0
  fi
  if [[ $state == "spent" && $named == "$relative" ]]; then
    if [[ $trial == "$relative" ]]; then
      aurora_trial_matches "$live.next" "$relative" running
      echo "Apple Silicon boot check: this boot is the Stage 2 trial of $relative, what Aurora's update-m1n1 builds now; aurora-stage2-commit.service makes it $stage2 once the boot is up"
      return 0
    fi
    (( live_matches )) ||
      fail "the Stage 2 trial of $relative fell back, so this Mac boots the previous $stage2 from the system ESP ($esp), not what Aurora's update-m1n1 builds now; the candidate is kept for inspection; $(aurora_remedy)"
    echo "Apple Silicon boot check: warning: an earlier Stage 2 trial of $relative fell back; $stage2 is current and the candidate is kept on the system ESP for inspection" >&2
    return 0
  fi
  if [[ $state == "spent" ]]; then
    aurora_foreign_marker=$named
    echo "Apple Silicon boot check: warning: aura-try on the system ESP ($esp) names $named, a trial Aurora's update-m1n1 does not manage" >&2
  fi
  if (( live_matches )); then
    ! sudo test -e "$live.next" ||
      echo "Apple Silicon boot check: warning: $relative is on the system ESP ($esp) with no aura-try marker arming it, an orphaned Stage 2 trial that no boot reads" >&2
    return 0
  fi
  ! sudo test -e "$live.next" ||
    fail "$stage2 on the system ESP ($esp) is not what Aurora's update-m1n1 builds now, and $relative is there with no aura-try marker arming it, an orphaned Stage 2 trial; $(aurora_remedy)"
  fail "$stage2 on the system ESP ($esp) is not aura, $kernel $kver's device trees, U-Boot and $CONFIG as Aurora's update-m1n1 builds them; $(aurora_remedy)"
}
