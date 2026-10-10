#!/bin/bash
# Tests of the packages against the Omarchy runtime. ROOT is the runtime checkout
# OMARCHY_TEST_RUNTIME names, with its own test helpers; without one the test skips.
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
requires_runtime "$(basename -- "$0")" || exit 0
source "$OMARCHY_TEST_RUNTIME/test/shell.d/base-test.sh"
# Tests name platforms x86, aarch64 and aarch64-apple. A runtime from before the
# rename (omacom/omarchy 5397950a2 and older) detects them as generic,
# generic-aarch64 and apple-silicon, and names its Apple list after the last.
runtime_platform() {
  if [[ -e $ROOT/bin/omarchy-hw-aarch64-apple ]]; then
    printf '%s\n' "$1"
  else
    case $1 in
      x86) echo generic ;;
      aarch64) echo generic-aarch64 ;;
      aarch64-apple) echo apple-silicon ;;
      *) fail "runtime_platform knows the platform $1" ;;
    esac
  fi
}
