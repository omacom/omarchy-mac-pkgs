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
unit=omarchy-mac-touchid-pam.service
[[ -f $units/$unit && $(readlink "$units/multi-user.target.wants/$unit") == "../$unit" ]] &&
  grep -Fxq 'ExecStart=/usr/lib/omarchy-mac/touchid-pam' "$units/$unit" && [[ -x $work/root/usr/lib/omarchy-mac/touchid-pam ]] ||
  fail 'the sync runs at every boot without enabling'
[[ ! -e $units/omarchy-mac-touchid-pam.path ]] || fail "nothing rewrites the stacks while Omarchy's own setup edits them"
hook=$work/root/usr/share/libalpm/hooks/91-omarchy-mac-touchid-pam.hook
grep -Fxq 'Target = usr/lib/security/pam_aurora_touchid.so' "$hook" && grep -Fq 'systemd-detect-virt --quiet --chroot ||' "$hook" ||
  fail 'an update that brings the module syncs at once, and never in a chroot'
removal=$work/root/usr/share/libalpm/hooks/91-omarchy-mac-touchid-pam-remove.hook
grep -Fxq 'Operation = Remove' "$removal" && grep -Fxq 'When = PreTransaction' "$removal" &&
  grep -Fq '/usr/lib/omarchy-mac/touchid-pam --remove' "$removal" || fail 'removing the package or the module takes the lines out first'
consent=$units/aurora-touchid-rearm@.service.d/50-omarchy-mac-touchid.conf
grep -Fxq 'ConditionPathExists=/etc/omarchy-mac/touchid-on' "$consent" && grep -Fxq 'ConditionPathExists=/dev/sep-bio-rearm' "$consent" ||
  fail "the helper answers only on the owner's record and a kernel with the re-arm node"
pass 'the sync, its boot unit, its pacman hooks and the helper condition are staged'

mkdir -p "$work/bin" "$work/pam.d" "$work/etc"
printf '#!/bin/sh\n[ ! -e "%s" ]\n' "$work/not-a-mac" >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
touch "$work/pam_aurora_touchid.so"
sync() {
  OMARCHY_MAC_TOUCHID_AGREED=$work/etc/touchid-on OMARCHY_MAC_PAMD=$work/pam.d \
    OMARCHY_MAC_TOUCHID_PAM_MODULE=$work/pam_aurora_touchid.so \
    OMARCHY_MAC_TOUCHID_PAM_LOCK=$work/run/touchid-pam.lock PATH="$work/bin:$PATH" \
    "$ROOT/lib/touchid-pam" "$@" >"$work/out" 2>&1
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
touch "$work/etc/touchid-on"
sync && sync --remove && cmp -s "$work/sudo" "$work/pam.d/sudo" && cmp -s "$work/polkit-1" "$work/pam.d/polkit-1" ||
  fail '--remove takes them out whatever the record says'
sync && mv "$work/pam_aurora_touchid.so" "$work/gone.so" && sync && cmp -s "$work/sudo" "$work/pam.d/sudo" ||
  fail 'without the module the lines go'
mv "$work/gone.so" "$work/pam_aurora_touchid.so"
rm "$work/etc/touchid-on"
pass 'without the record or the module, or with --remove, the module and its comment go, and nothing else'

# Only the managed block is ours: an administrator's own line stays, and the
# block goes even when the include it followed has changed.
printf 'auth include system-auth\n%s\naccount include system-auth\n' "$module" >"$work/own"
cp "$work/own" "$work/pam.d/sudo"
sync && cmp -s "$work/own" "$work/pam.d/sudo" || fail "an administrator's own module line is never removed"
printf 'auth substack system-auth\n%s\n%s\naccount include system-auth\n' "$marker" "$module" >"$work/pam.d/sudo"
sync && [[ $(<"$work/pam.d/sudo") == $'auth substack system-auth\naccount include system-auth' ]] ||
  fail 'the managed block goes even after its include changed' "$(<"$work/pam.d/sudo")"
cp "$work/sudo" "$work/pam.d/sudo"
pass 'only the managed block is ever removed'

touch "$work/etc/touchid-on"
rm "$work/pam.d/polkit-1"
for stack in 'auth include system-auth\nauth include system-auth' 'auth include system-auth\nauth required pam_u2f.so' \
  'auth [success=1 default=ignore] pam_exec.so quiet /bin/true\nauth required pam_deny.so'; do
  printf "$stack\naccount include system-auth\n" >"$work/odd"
  cp "$work/odd" "$work/pam.d/sudo"
  sync || fail 'a stack it cannot place the line in is not an error' "$(cat "$work/out")"
  cmp -s "$work/odd" "$work/pam.d/sudo" && grep -Fq "isn't its only 'auth include system-auth'" "$work/out" ||
    fail 'a stack whose last auth line is not its only system-auth include stays as it is and says why' "$stack"
done
[[ ! -e $work/pam.d/polkit-1 ]] || fail 'a missing polkit stack is not created'
ln -sfn "$work/sudo" "$work/pam.d/polkit-1"
sync && [[ -L $work/pam.d/polkit-1 ]] && cmp -s "$work/sudo" "$work/pam.d/polkit-1" || fail 'a symlinked stack is left alone'
pass 'a stack where the include is not the single last auth line, a missing one and a symlink are left alone'

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
