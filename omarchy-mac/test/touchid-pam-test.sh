#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# While the owner has Touch ID on, sudo's and polkit's stacks carry
# pam_aurora_touchid after their system-auth include, so a password there
# re-arms a locked Touch ID; turning Touch ID off takes it out again.
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
for unit in omarchy-mac-touchid-pam.service omarchy-mac-touchid-pam.path; do
  [[ -f $units/$unit && $(readlink "$units/multi-user.target.wants/$unit") == "../$unit" ]] ||
    fail "$unit is staged and pulled in at boot without enabling"
done
grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/touchid-pam' "$units/omarchy-mac-touchid-pam.service" &&
  grep -Fxq 'PathChanged=/etc/pam.d/sudo' "$units/omarchy-mac-touchid-pam.path" &&
  grep -Fxq 'PathChanged=/etc/pam.d/polkit-1' "$units/omarchy-mac-touchid-pam.path" &&
  [[ -x $work/root/usr/lib/omarchy-mac/touchid-pam ]] ||
  fail 'the sync runs at boot and whenever sudo or polkit stacks change'
hook=$work/root/usr/share/libalpm/hooks/91-omarchy-mac-touchid-pam.hook
grep -Fxq 'Target = usr/lib/security/pam_aurora_touchid.so' "$hook" && grep -Fq 'systemd-detect-virt --quiet --chroot ||' "$hook" ||
  fail 'an update that brings the module syncs at once, and never in a chroot'
pass 'the sync, its units and its pacman hook are staged'

mkdir -p "$work/bin" "$work/pam.d" "$work/etc"
printf '#!/bin/sh\n[ ! -e "%s" ]\n' "$work/not-a-mac" >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
sync() {
  OMARCHY_MAC_TOUCHID_AGREED=$work/etc/touchid-on OMARCHY_MAC_PAMD=$work/pam.d \
    OMARCHY_MAC_TOUCHID_PAM_LOCK=$work/run/touchid-pam.lock PATH="$work/bin:$PATH" \
    "$ROOT/lib/touchid-pam" >"$work/out" 2>&1
}
module='-auth      optional                    pam_aurora_touchid.so'
marker='# omarchy-mac: a password here re-arms Touch ID; turning Touch ID off removes this'

# Arch's sudo, and polkit as Omarchy's fingerprint setup writes it.
cat >"$work/sudo" <<'EOF'
#%PAM-1.0
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth		include		system-auth
account		include		system-auth
session		include		system-auth
EOF
cat >"$work/polkit-1" <<'EOF'
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      include system-auth

account   include system-auth
password  include system-auth
session   include system-auth
EOF
cp "$work/sudo" "$work/polkit-1" "$work/pam.d/"
chmod 0640 "$work/pam.d/sudo"

sync || fail 'nothing to do on a Mac whose owner has not turned Touch ID on' "$(cat "$work/out")"
cmp -s "$work/sudo" "$work/pam.d/sudo" && cmp -s "$work/polkit-1" "$work/pam.d/polkit-1" ||
  fail 'stacks stay as they are without the owner'\''s record'
pass 'without the record nothing changes'

touch "$work/etc/touchid-on"
sync || fail 'the lines are added' "$(cat "$work/out")"
for service in sudo polkit-1; do
  file=$work/pam.d/$service
  [[ $(grep -Fxc -- "$module" "$file") == 1 ]] || fail "$service carries the module once"
  after=$(grep -A2 -E '^auth[[:space:]]+include[[:space:]]+system-auth' "$file" | tail -2)
  [[ $after == "$marker"$'\n'"$module" ]] || fail "$service has the module straight after its system-auth include" "$after"
  diff <(grep -Fxv -e "$module" -e "$marker" "$file") "$work/$service" >/dev/null ||
    fail "$service keeps every other line, in order"
done
[[ $(stat -c %a "$work/pam.d/sudo") == 640 ]] || fail 'the stack keeps its mode'
cp "$work/pam.d/sudo" "$work/sudo.once"
sync && cmp -s "$work/sudo.once" "$work/pam.d/sudo" || fail 'a second run changes nothing'
pass 'with the record the module follows the system-auth include of sudo and polkit, once, and the rest stays'

rm "$work/etc/touchid-on"
sync || fail 'the lines are removed' "$(cat "$work/out")"
cmp -s "$work/sudo" "$work/pam.d/sudo" && cmp -s "$work/polkit-1" "$work/pam.d/polkit-1" ||
  fail 'turning Touch ID off gives back the stacks as they were'
pass 'without the record the module and its comment go, and nothing else'

touch "$work/etc/touchid-on"
rm "$work/pam.d/polkit-1"
printf 'auth include system-auth\nauth include system-auth\n' >"$work/twice"
cp "$work/twice" "$work/pam.d/sudo"
sync || fail 'a stack it cannot place the line in is not an error' "$(cat "$work/out")"
cmp -s "$work/twice" "$work/pam.d/sudo" && grep -Fq "exactly one 'auth include system-auth'" "$work/out" &&
  [[ ! -e $work/pam.d/polkit-1 ]] || fail 'an unusual stack stays as it is and says why; a missing polkit stack is not created'
ln -sfn "$work/sudo" "$work/pam.d/polkit-1"
sync && [[ -L $work/pam.d/polkit-1 ]] && cmp -s "$work/sudo" "$work/pam.d/polkit-1" || fail 'a symlinked stack is left alone'
pass 'a stack with no single system-auth include, a missing one and a symlink are left alone'

cp "$work/sudo" "$work/pam.d/sudo"
rm "$work/pam.d/polkit-1"
printf '#!/bin/sh\nexit 2\n' >"$work/bin/awk"
chmod +x "$work/bin/awk"
! sync && cmp -s "$work/sudo" "$work/pam.d/sudo" || fail 'an edit that fails never writes the stack, and says so'
rm "$work/bin/awk"
pass 'a failed edit leaves sudo as it was'

touch "$work/not-a-mac"
sync && cmp -s "$work/sudo" "$work/pam.d/sudo" || fail 'off a Mac it changes nothing'
pass 'off a Mac nothing changes'
