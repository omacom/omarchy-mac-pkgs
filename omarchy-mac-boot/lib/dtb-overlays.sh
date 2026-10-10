# shellcheck shell=dash
# Package-owned device tree overlays for m1n1 stage 2 (sh with local).
#
# A package that adds hardware support the kernel's device trees lack ships a
# compiled overlay as /usr/lib/omarchy-mac-boot/dtb-overlays/PREFIX/NAME.dtbo.
# It applies to every device tree whose file name is PREFIX.dtb or starts with
# PREFIX- ("t8103" covers every M1 board, "t6001-j316c" one board). A device
# tree takes its overlays in C order of PREFIX/NAME. An overlay whose root node
# has the string list "omarchy,skip-if-compatible" is left out of a device tree
# that already has an available node with one of those compatibles (Linux's
# of_device_is_available(): no status, "okay" or "ok"), so a kernel that gains
# the node wins. An overlay whose root node has the string "omarchy,opt-in"
# applies only when that string is a line of
# /etc/omarchy-mac-boot/dtb-overlays.opt-in: the owner's choice for hardware
# whose driver must not start by default. When an overlay does not apply, or
# dtc cannot read the result, that device tree stays as the kernel shipped it.
# With no overlays, nothing changes.
#
# /etc/default/update-m1n1 calls dtb_overlays_update_m1n1 to set DTBS; the
# boot check sources the same configuration the same way to rebuild the same
# image. OMARCHY_DTB_OVERLAYS_ROOT prefixes every path read or written. Where
# the copies and their manifest land is dtb_overlays_outdir()'s decision: the
# boot check and the tests replace that one function, never the environment.
# OMARCHY_DTB_OVERLAYS=0 turns the merge off.

dtb_overlays_dir() {
  printf '%s\n' "${OMARCHY_DTB_OVERLAYS_ROOT:-}/usr/lib/omarchy-mac-boot/dtb-overlays"
}

dtb_overlays_outdir() {
  printf '%s\n' "${OMARCHY_DTB_OVERLAYS_ROOT:-}/run/omarchy-dtb-overlays"
}

# The overlays, one path per line, in the order they apply.
dtb_overlays_list() {
  (
    LC_ALL=C
    for overlay in "$(dtb_overlays_dir)"/*/*.dtbo; do
      if [ -f "$overlay" ]; then
        printf '%s\n' "$overlay"
      fi
    done
  )
}

# dtc, fdtoverlay and fdtget, from dtc 1.7.1 or newer: older fdtoverlay gives
# an existing node a new phandle when an overlay labels it, and every
# reference to the old one then points nowhere.
dtb_overlays_tools() {
  local version
  command -v dtc >/dev/null 2>&1 && command -v fdtoverlay >/dev/null 2>&1 &&
    command -v fdtget >/dev/null 2>&1 || return 1
  # "Version: DTC v1.8.1" on Arch, "Version: DTC 1.6.1" on Debian.
  version=$(dtc --version 2>/dev/null | sed -n 's/^Version: DTC v\{0,1\}\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\).*/\1 \2 \3/p')
  # shellcheck disable=SC2086 # split into major minor patch
  set -- $version
  [ $# = 3 ] || return 1
  [ "$1" -gt 1 ] || { [ "$1" = 1 ] && { [ "$2" -gt 7 ] || { [ "$2" = 7 ] && [ "$3" -ge 1 ]; }; }; }
}

# True when UPDATE_M1N1 has the DTBS default dtb_overlays_update_m1n1
# reproduces: asahi-scripts with the default Arch Linux ARM adds.
dtb_overlays_supported() {
  # shellcheck disable=SC2016 # the literal default line
  grep -Fqx -- ': ${DTBS:=$(/bin/ls -d /lib/modules/*-ARCH | sort -rV | head -1)/dtbs/*.dtb}' "$1"
}

# True when DTB has an available node whose compatible list holds COMPATIBLE.
# Available is Linux's of_device_is_available(): the node has no status, or
# its status is "okay" or "ok". A disabled node does not count.
dtb_overlays_has_compatible() {
  dtc -q -I dtb -O dts -o - "$1" 2>/dev/null | awk -v compatible="\"$2\"" '
    {
      if ($0 ~ /^[[:space:]]*\}[;]?[[:space:]]*$/) {
        if (matched[depth] && (status[depth] == "" || status[depth] == "okay" ||
          status[depth] == "ok")) {
          found = 1
          exit
        }
        delete matched[depth]
        delete status[depth]
        depth--
      } else if ($0 ~ /\{[[:space:]]*$/) {
        depth++
      } else if ($0 ~ /^[[:space:]]*compatible[[:space:]]*=/ && index($0, compatible)) {
        matched[depth] = 1
      } else if ($0 ~ /^[[:space:]]*status[[:space:]]*=/ && match($0, /"[^"]*"/)) {
        status[depth] = substr($0, RSTART + 1, RLENGTH - 2)
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Writes OUT: DTB with every overlay in OVERLAYS (newline-separated) that
# applies to it. Returns 1, and writes nothing, when none applies or one fails.
dtb_overlays_build() {
  local dtb="$1" out="$2" overlays="$3" name="${1##*/}" applied=0 overlay prefix skip compatible key
  local opt_in="${OMARCHY_DTB_OVERLAYS_ROOT:-}/etc/omarchy-mac-boot/dtb-overlays.opt-in"
  cp -- "$dtb" "$out.base" || return 1
  for overlay in $overlays; do
    prefix=${overlay%/*}
    prefix=${prefix##*/}
    case "$name" in
      "$prefix.dtb" | "$prefix"-*) ;;
      *) continue ;;
    esac
    skip=0
    for key in $(fdtget -t s "$overlay" / omarchy,opt-in 2>/dev/null); do
      grep -Fqx -- "$key" "$opt_in" 2>/dev/null || skip=1
    done
    for compatible in $(fdtget -t s "$overlay" / omarchy,skip-if-compatible 2>/dev/null); do
      if dtb_overlays_has_compatible "$out.base" "$compatible"; then
        skip=1
      fi
    done
    [ "$skip" = 0 ] || continue
    if fdtoverlay -i "$out.base" -o "$out.next" "$overlay" 2>/dev/null &&
      dtc -q -I dtb -O dtb -o /dev/null "$out.next" 2>/dev/null; then
      mv -f -- "$out.next" "$out.base"
      applied=1
    else
      dtb_overlays_note "$overlay does not apply to $name; $name stays as the kernel shipped it"
      rm -f -- "$out.next" "$out.base"
      return 1
    fi
  done
  if [ "$applied" = 0 ]; then
    rm -f -- "$out.base"
    return 1
  fi
  mv -f -- "$out.base" "$out"
}

# Applies the overlays to every device tree the DTBS words expand to under
# the root, and writes a manifest in the outdir: overlayN to the source tree,
# one line per expanded tree, in apply order. Prints the list that replaces
# DTBS: the copy for a tree the overlays changed, the tree itself otherwise.
dtb_overlays_apply() {
  local root="${OMARCHY_DTB_OVERLAYS_ROOT:-}" outdir="$1" overlays out n=0 word dtb glued part
  shift
  overlays=$(dtb_overlays_list)
  if [ -z "$overlays" ] || ! dtb_overlays_tools; then
    overlays=""
  fi
  : >"$outdir/manifest"
  # Every DTBS word is a device tree path: glue the root to each of its
  # fields, then let the fields glob. A word that matches nothing stays a
  # glued literal and fails the copy, like a missing tree does for real.
  for word in "$@"; do
    glued=""
    set -f
    for part in $word; do
      glued="$glued $root$part"
    done
    set +f
    for dtb in $glued; do
      n=$(( n + 1 ))
      out=$outdir/overlay$n
      if [ -n "$overlays" ] && dtb_overlays_build "$dtb" "$out" "$overlays"; then
        printf '%s %s\n' "${out##*/}" "${dtb#"$root"}" >>"$outdir/manifest"
        printf '%s\n' "$out"
      else
        printf '%s\n' "$dtb"
      fi
    done
  done
}

# Why the overlays are left out, on stderr. The boot check replaces this to
# keep the library's notes apart from anything else the configuration prints.
dtb_overlays_note() {
  echo "dtb-overlays: $*" >&2
}

# Sets DTBS for update-m1n1, with the overlaid copy of every device tree an
# overlay applies to: over the DTBS the configuration already set, or, with
# none set, over the newest kernel's device trees. With overlays installed and
# supported it always assigns DTBS, the expanded list even when no overlay
# applies, so a later ': ${DTBS:=...}' no longer fires; otherwise it leaves
# DTBS as it was. The copies and their manifest land where
# dtb_overlays_outdir points. A DTBS word already under that directory is a
# copy from an earlier call and is resolved back to its source through the
# manifest before the cleanup. OMARCHY_DTB_OVERLAYS_CALLED records the call.
dtb_overlays_update_m1n1() {
  local root="${OMARCHY_DTB_OVERLAYS_ROOT:-}" modules outdir manifest key_dir resolved word src
  # shellcheck disable=SC2034 # read by the boot check after the configuration
  OMARCHY_DTB_OVERLAYS_CALLED=1
  outdir=$(dtb_overlays_outdir)
  [ "${OMARCHY_DTB_OVERLAYS:-1}" != 0 ] || return 0
  [ -n "$(dtb_overlays_list)" ] || return 0
  if ! dtb_overlays_supported "$root/usr/bin/update-m1n1"; then
    dtb_overlays_note "/usr/bin/update-m1n1 has a DTBS default this does not reproduce; device tree overlays are not applied"
    return 0
  fi
  if ! dtb_overlays_tools; then
    dtb_overlays_note "device tree overlays need dtc 1.7.1 or newer (dtc, fdtoverlay and fdtget); install or update dtc"
    return 0
  fi
  if [ -n "${DTBS:-}" ] && [ -d "$root$DTBS" ] && grep -Fq -- '-d "$DTBS"' "$root/usr/bin/update-m1n1"; then
    DTBS="$DTBS/apple/t6*.dtb $DTBS/apple/t81*.dtb"
  fi
  # Words a previous call left in the outdir are copies, and their sources are
  # in the manifest. Resolve them back to their sources before the cleanup, so
  # a second call cannot delete a copy's own input and abort update-m1n1.
  # Apply glues the root onto every word, so the resolved list is root-less.
  manifest=$outdir/manifest
  if [ -f "$manifest" ] && [ -n "${DTBS:-}" ]; then
    key_dir=$outdir
    if [ -n "$root" ]; then
      case $key_dir in "$root"/*) key_dir=${key_dir#"$root"} ;; esac
    fi
    resolved=""
    set -f
    for word in ${DTBS:-}; do
      if [ -n "$root" ]; then
        case $word in "$root"/*) word=${word#"$root"} ;; esac
      fi
      case $word in
        "$key_dir"/*)
          src=$(sed -n "s/^${word#"$key_dir"/} //p" "$manifest" | head -n 1)
          resolved="$resolved ${src:-$word}"
          ;;
        *) resolved="$resolved $word" ;;
      esac
    done
    set +f
    DTBS=${resolved# }
  fi
  # The outdir is never removed: other files an administrator may keep there
  # stay, and only this call's own outputs go.
  rm -f -- "$outdir"/overlay* "$outdir/manifest"
  mkdir -p -- "$outdir" || return 0
  if [ -n "${DTBS:-}" ]; then
    DTBS=$(dtb_overlays_apply "$outdir" "$DTBS" | tr '\n' ' ')
  else
    modules=$(/bin/ls -d "$root"/lib/modules/*-ARCH | sort -rV | head -1)
    modules=${modules#"$root"}
    DTBS=$(dtb_overlays_apply "$outdir" "$modules/dtbs/*.dtb" | tr '\n' ' ')
  fi
  DTBS=${DTBS% }
}
