#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
units=$work/root/usr/lib/systemd/system
unit=$units/omarchy-mac-touchid-statecheck.service
grep -Fxq 'Type=oneshot' "$unit" && grep -Fxq 'Before=omarchy-mac-touchid-load.service omarchy-mac-touchid-activate.service fprintd.service' "$unit" || fail 'host state admission is a distinct oneshot dependency'
grep -Fxq 'Requires=omarchy-mac-touchid-statecheck.service omarchy-mac-touchid-load.service' "$units/fprintd.service.d/50-omarchy-mac-touchid.conf" || fail 'fprintd requires host admission'
! grep -Eq '^Exec(Start|StartPre)=' "$units/fprintd.service.d/50-omarchy-mac-touchid.conf" || fail 'fprintd has no admission command inside its sandbox'
! grep -Eq '^(ProtectSystem|PrivateTmp|PrivateMounts|RootDirectory)=' "$unit" || fail 'admission sees the global mount namespace'
for name in load activate; do
  grep -Fxq 'ExecStartPre=/usr/lib/omarchy-mac/touchid-statecheck' "$units/omarchy-mac-touchid-$name.service" || fail 'unsandboxed load/activate recheck before use'
done
! grep -Eq '^OnFailure=' "$unit" || fail 'admission failure never escalates boot'
mkdir -p "$work/bin"
cat >"$work/bin/stat" <<'STUB'
#!/bin/bash
value=$(/usr/bin/stat "$@") || exit
if [[ $* == *"%u:%g:%a"* ]]; then printf '0:0:%s\n' "${value#*:*:}"; else printf '%s\n' "$value"; fi
STUB
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/"*
run() { PATH="$work/bin:$PATH" OMARCHY_MAC_TOUCHID_STATECHECK=$work/site "$ROOT/lib/touchid-statecheck"; }
run || fail 'normal Macs without a site hook are unchanged'
printf '#!/bin/bash\nprintf "host namespace\\n" >"%s"\n' "$work/result" >"$work/site"
chmod 0700 "$work/site"
run && grep -Fxq 'host namespace' "$work/result" || fail 'site check runs from the unsandboxed helper'
printf '#!/bin/bash\nexit 1\n' >"$work/site"
! run || fail 'failed admission blocks its consumer'
chmod 0722 "$work/site"
! run >/dev/null 2>&1 || fail 'writable admission program is refused'
rm "$work/site";ln -s /missing "$work/site"
! run >/dev/null 2>&1 || fail 'dangling admission hook never counts as absent'
pass 'admission is outside fprintd, optional without migration, and failures stay local'
