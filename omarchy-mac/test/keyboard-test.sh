#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/root"
"$ROOT/install" "$stage"

[[ -d $stage/usr/lib/modprobe.d ]] && ! grep -rqs hid_apple "$stage/usr/lib/modprobe.d" || fail 'the package ships no hid_apple option'
pass 'the package ships no hid_apple option, so the kernel default applies'
