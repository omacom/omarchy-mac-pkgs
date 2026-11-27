#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The warm-up is pulled in at boot without enabling and runs before the greeter.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
unit=$units/omarchy-mac-m5-gpu-warmup.service
[[ -f $unit && $(readlink "$units/multi-user.target.wants/omarchy-mac-m5-gpu-warmup.service") == "../omarchy-mac-m5-gpu-warmup.service" ]] ||
  fail 'the warm-up unit is staged and pulled in at boot without enabling'
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/m5-gpu-warmup' "$unit" && grep -Fxq 'Before=display-manager.service' "$unit" ||
  fail 'the warm-up runs before the display manager'
grep -Fq 'aurora-silicon/linux#2727' "$unit" || fail 'the unit names the issue whose fix removes it'
[[ -x $work/root/usr/lib/omarchy-mac/m5-gpu-warmup && -x $work/root/usr/lib/omarchy-mac/m5-gpu-warmup-render ]] ||
  fail 'the warm-up and its renderer are staged executable'
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$ROOT/lib/m5-gpu-warmup-render" || fail 'the renderer parses'
pass 'the warm-up unit, its boot link, its script and its renderer are staged'

# Only a T8142 runs the renderer, on the render node, 4 frames at 64x64.
fixture=$work/fixture
mkdir -p "$fixture/tree" "$fixture/dev"
printf '#!/bin/bash\necho "$@" >>"%s"\n' "$fixture/calls" >"$fixture/render"
chmod +x "$fixture/render"
touch "$fixture/dev/renderD128"
warmup() {
  rm -f "$fixture/calls"
  OMARCHY_MAC_GPU_WARMUP_TREE=$fixture/tree OMARCHY_MAC_GPU_WARMUP_NODE=$fixture/dev/renderD128 \
    OMARCHY_MAC_GPU_WARMUP_RENDER=$fixture/render "$ROOT/lib/m5-gpu-warmup"
}
for board in 'apple,j815\0apple,t8142\0apple,arm-platform\0' 'apple,j704\0apple,t8142\0apple,arm-platform\0'; do
  printf "$board" >"$fixture/tree/compatible"
  warmup >/dev/null
  [[ $(cat "$fixture/calls") == "$fixture/dev/renderD128 64 64 4" ]] || fail 'a T8142 renders 4 frames at 64x64 on the render node'
done
pass 'a T8142 renders 4 frames at 64x64 on the render node'

for board in 'apple,j700\0apple,t8140\0apple,arm-platform\0' 'apple,j714c\0apple,t6050\0apple,arm-platform\0' \
  'apple,j414c\0apple,t6021\0apple,arm-platform\0' 'apple,j8142\0apple,t81420\0apple,arm-platform\0'; do
  printf "$board" >"$fixture/tree/compatible"
  warmup >/dev/null || fail 'another Mac exits 0'
  [[ ! -e $fixture/calls ]] || fail "another Mac never runs the renderer ($board)"
done
rm "$fixture/tree/compatible"
warmup >/dev/null && [[ ! -e $fixture/calls ]] || fail 'a tree without compatible runs nothing'
pass 'no other Mac, the M5 Max included, runs the renderer'

# A T8142 whose GPU never came up still lets the greeter start.
printf 'apple,j815\0apple,t8142\0' >"$fixture/tree/compatible"
rm "$fixture/dev/renderD128"
output=$(warmup) || fail 'a missing render node is not a failure'
[[ ! -e $fixture/calls && $output == "No GPU render node at $fixture/dev/renderD128; no warm-up" ]] ||
  fail 'a missing render node skips the warm-up and says so'
pass 'a T8142 without a render node skips the warm-up after waiting'

if command -v systemd-analyze >/dev/null; then
  stub_systemd_boot_targets "$work/root"
  printf '[Service]\nExecStart=sh -c true\n' >"$units/probe.service"
  if verify=$(systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/omarchy-mac-m5-gpu-warmup.service 2>&1) && [[ -z $verify ]]; then
    pass 'systemd accepts the warm-up unit without warnings'
  elif probe=$(systemd-analyze --root="$work/root" verify --man=no /usr/lib/systemd/system/probe.service 2>&1) && [[ -z $probe ]]; then
    fail 'systemd accepts the warm-up unit without warnings' "$verify"
  else
    pass 'systemd-analyze cannot verify units here; unit verification not run'
  fi
fi
