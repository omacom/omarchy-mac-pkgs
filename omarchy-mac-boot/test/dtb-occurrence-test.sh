#!/bin/bash

set -euo pipefail
source "$(dirname -- "$0")/base-test.sh"
require_command dtc
require_command gzip

checker=${DTB_OCCURRENCE_CHECKER:-$ROOT/bin/omarchy-apple-silicon-boot-check}
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Execute the checker's image assembly and hash comparison with real DTBs.
# Only the surrounding package lookup and ESP mount are outside this test.
for function in dtb_reset dtb_file_for m1n1_options build_image dtb_order; do
  source <(sed -n "/^$function() {/,/^}/p" "$checker")
done

root="" CONFIG=$test_tmp/no-options M1N1=$test_tmp/m1n1 U_BOOT=$test_tmp/u-boot
printf 'm1n1\n' >"$M1N1"
printf 'U-Boot\n' >"$U_BOOT"
for name in plain overlaid; do
  dtc -q -I dts -O dtb -o "$test_tmp/$name.dtb" - <<DTS
/dts-v1/;
/ { compatible = "apple,j274", "apple,t8103"; test-content = "$name"; };
DTS
done

source_tree=/usr/lib/modules/test-ARCH/dtbs/t8103-j274.dtb
dtbs=("$source_tree" "$source_tree")
declare -A dtb_next=()

for order in overlaid-first plain-first; do
  if [[ $order == "overlaid-first" ]]; then
    dtb_paths=("$test_tmp/overlaid.dtb" "$test_tmp/plain.dtb")
  else
    dtb_paths=("$test_tmp/plain.dtb" "$test_tmp/overlaid.dtb")
  fi
  build_image "$test_tmp/rebuilt.bin" "${dtbs[@]}"
  {
    cat "$M1N1" "${dtb_paths[@]}"
    gzip -c "$U_BOOT"
  } >"$test_tmp/expected.bin"
  cmp -s "$test_tmp/rebuilt.bin" "$test_tmp/expected.bin" ||
    fail "$order keeps each occurrence's bytes in the rebuilt image"
  cat "${dtb_paths[@]}" >"$test_tmp/mixed.bin"
  dtb_order "$test_tmp/mixed.bin" 0 >"$test_tmp/order" ||
    fail "$order accepts both configured occurrences"
  [[ $(wc -l <"$test_tmp/order") == 2 ]] || fail "both occurrences are counted"
  cat "${dtb_paths[0]}" "${dtb_paths[0]}" >"$test_tmp/duplicate-first.bin"
  if dtb_order "$test_tmp/duplicate-first.bin" 0 >/dev/null; then
    fail "$order rejects two copies of its first occurrence"
  fi
  cat "${dtb_paths[1]}" "${dtb_paths[0]}" >"$test_tmp/reordered.bin"
  dtb_order "$test_tmp/reordered.bin" 0 >/dev/null ||
    fail "$order still accepts the configured bytes in a different order"
  if (build_image "$test_tmp/extra.bin" "$source_tree" "$source_tree" "$source_tree") 2>/dev/null; then
    fail "$order refuses more occurrences than DTBS provides"
  fi
  pass "$order preserves mixed occurrences, rejects duplicates and keeps reorder support"
done
