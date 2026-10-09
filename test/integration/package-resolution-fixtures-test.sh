#!/bin/bash
# The package-resolution fixtures resolve the same repositories, in the same
# order, as the runtime's edge template for each platform.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
repositories() { grep -o '^\[[^]]*\]' "$1" | tr -d '[]' | grep -vx options | tr '\n' ' '; }
for fixture in "apple:$ROOT/default/pacman/apple-silicon" "generic-aarch64:$ROOT/default/pacman/aarch64"; do
  [[ $(repositories "$REPO/tools/package-resolution/platforms/${fixture%%:*}/pacman.conf") == \
    "$(repositories "${fixture#*:}/pacman-edge.conf")" ]] ||
    fail "the ${fixture%%:*} resolution fixture follows ${fixture#*:}"
done
pass "package-resolution fixtures follow each platform's repositories"
