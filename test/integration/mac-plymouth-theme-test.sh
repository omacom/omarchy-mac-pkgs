#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# omarchy-mac-boot appends its first-boot addendum to the runtime's Omarchy
# Plymouth theme in the initramfs. Everything the addendum calls or reads must
# exist in that theme, or Plymouth drops the script and shows no splash.

theme=$OMARCHY_TEST_RUNTIME/default/plymouth/omarchy.script
[[ -f $theme ]] || fail "the runtime ships the Omarchy Plymouth theme" "$theme"

for function in stop_fake_progress hide_password_dialog show_progress_bar update_progress_bar progress_callback refresh_callback; do
  grep -Eq "^fun $function\(" "$theme" || fail "the runtime theme defines $function"
done
for name in progress_box.y progress_box.image progress_bar.original_image progress_bar.sprite message_sprite global.max_progress; do
  grep -Fq "$name" "$theme" || fail "the runtime theme defines $name"
done
pass "the runtime theme has every function and sprite the Mac addendum uses"

# The addendum hands update_progress_bar a 0-1 fraction (system-update sends 0-100).
grep -Fq 'progress_bar.original_image.GetWidth() * progress' "$theme" ||
  fail "the runtime theme's update_progress_bar still scales the bar by a 0-1 fraction"
pass "the runtime theme's bar takes the fraction the addendum passes"

! grep -Fq 'SetSystemUpdateFunction' "$theme" ||
  fail "the runtime theme now handles system-update itself; drop the Mac addendum" "$theme"
pass "the runtime theme leaves system-update to the Mac addendum"
