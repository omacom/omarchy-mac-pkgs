# The M3 Airs' native display: m1n1 hands the display coprocessor to Linux only
# when /etc/m1n1.conf sets chosen.asahi,t8122-dcp=1, which update-m1n1 copies
# into boot.bin. An m1n1 without its opt-in gate black-screens these Macs with it.
omarchy-hw-apple-silicon || return 0
[[ ${OMARCHY_MAC_IMAGE_BUILD:-} != "1" ]] || return 0
# setup-boot clears the environment, so only a booted systemd tells the leaf it
# is not in a chroot (an image build's or an installer's).
[[ -d ${OMARCHY_SYSTEMD_RUN:-/run/systemd/system} ]] || return 0

(
  set -uo pipefail
  # The first m1n1-aurora whose T8122 display handoff waits for that line.
  # Empty until omarchy-pkgs publishes it: nothing is written until then.
  m1n1_t8122_dcp_minimum=
  minimum_m1n1=${OMARCHY_M1N1_T8122_DCP_MINIMUM-$m1n1_t8122_dcp_minimum}
  compatible=${OMARCHY_DEVICE_TREE_COMPATIBLE:-/proc/device-tree/compatible}
  config=${OMARCHY_M1N1_CONF:-/etc/m1n1.conf}
  key=chosen.asahi,t8122-dcp

  machine=
  [[ ! -r $compatible ]] || machine=$(tr '\0' '\n' <"$compatible")
  m1n1_display_has() { [[ $'\n'$machine$'\n' == *$'\n'"$1"$'\n'* ]]; }

  m1n1_display_has apple,t8122 || exit 0
  # The M3 Airs (J613, J615); the other T8122 Macs' displays are untested.
  m1n1_display_has apple,j613 || m1n1_display_has apple,j615 || exit 0
  if [[ -z $minimum_m1n1 ]]; then
    echo "m1n1-display: no m1n1-aurora with the T8122 display opt-in is known yet; leaving $config alone"
    exit 0
  fi
  # pacman -Q also answers for a package that only provides the name.
  name= installed=
  read -r name installed < <(pacman -Q m1n1-aurora 2>/dev/null) || true
  if [[ $name != "m1n1-aurora" || -z $installed ]]; then
    echo "m1n1-display: m1n1-aurora is not installed; leaving $config alone"
    exit 0
  fi
  # Fail closed: a comparison that cannot be made writes nothing.
  if ! order=$(vercmp "$installed" "$minimum_m1n1" 2>/dev/null) || [[ ! $order =~ ^-?[0-9]+$ ]]; then
    echo "m1n1-display: cannot compare m1n1-aurora $installed with $minimum_m1n1; leaving $config alone"
    exit 0
  fi
  if (( order < 0 )); then
    echo "m1n1-display: m1n1-aurora $installed predates the T8122 display opt-in ($minimum_m1n1); leaving $config alone"
    exit 0
  fi
  # A line the owner wrote, for either value, is theirs to keep.
  if [[ -r $config ]] && grep -Eq "^[[:space:]]*${key//./\\.}=" "$config"; then
    exit 0
  fi

  staged=$(mktemp -d) || { echo "m1n1-display: could not stage $config; leaving it alone" >&2; exit 0; }
  trap 'rm -rf "$staged"' EXIT
  : >"$staged/new"
  if [[ -e $config ]]; then
    cp "$config" "$staged/original" && cp "$config" "$staged/new" ||
      { echo "m1n1-display: could not stage $config; leaving it alone" >&2; exit 0; }
    # Keep a last line without its newline from swallowing ours.
    [[ ! -s $staged/new || $(tail -c 1 "$staged/new" | od -An -c | tr -d ' ') == '\n' ]] || printf '\n' >>"$staged/new"
  fi
  printf '# omarchy-mac-boot: the M3 Air native display. Set it to 0 to keep m1n1 from handing it over.\n%s=1\n' "$key" >>"$staged/new"

  # Put the original bytes back (install can unlink the file before copying).
  m1n1_display_restore() {
    if [[ -e $staged/original ]]; then
      sudo install -m 0644 "$staged/original" "$config"
    else
      sudo rm -f "$config"
    fi
  }
  m1n1_display_failed() {
    if m1n1_display_restore; then
      echo "m1n1-display: $1; $config is back as it was, and the native display stays off" >&2
    else
      echo "m1n1-display: $1, and $config could not be put back; the next update-m1n1 takes its $key line" >&2
    fi
    exit 0
  }
  sudo install -D -m 0644 "$staged/new" "$config" || m1n1_display_failed "could not write $config"
  # boot.bin only takes m1n1.conf when update-m1n1 builds it.
  sudo update-m1n1 || m1n1_display_failed "update-m1n1 failed"
  echo "m1n1-display: enabled the native display in $config"
)
