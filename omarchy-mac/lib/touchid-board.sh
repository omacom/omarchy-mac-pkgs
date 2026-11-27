#!/bin/bash
# Board predicates shared by the Touch ID helpers.
tree=${OMARCHY_MAC_TOUCHID_TREE:-/proc/device-tree}

compatible() {
  [[ -r $tree/compatible ]] && tr '\0' '\n' <"$tree/compatible" | grep -Fxq "$1"
}

guarded_m1() {
  { compatible apple,t8103 && compatible apple,j313; } ||
    { compatible apple,t6001 && compatible apple,j316c; }
}

sealed_board() {
  { compatible apple,t6040 && compatible apple,j616s; } ||
    { compatible apple,t6041 && compatible apple,j616c; }
}

other_touchid_board() {
  compatible apple,t8112 || compatible apple,t6020 || compatible apple,t6021 || compatible apple,t8140 ||
    { compatible apple,t8122 && { compatible apple,j613 || compatible apple,j615; }; } || sealed_board
}
