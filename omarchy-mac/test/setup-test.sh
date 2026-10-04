#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
[[ -z ${PLATFORM_ERROR:-} ]] || { echo "Error: $PLATFORM_ERROR" >&2; exit 1; }
echo "${PLATFORM:-apple-silicon}"
STUB
cat >"$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ $(omarchy-hw-platform) == "apple-silicon" ]]
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo "Broadcom [14e4:${WIFI_ID:-4433}]"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
exit "${SYSTEMCTL_STATUS:-0}"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" CALLS="$work/calls"
stage="$work/root"
"$ROOT/install" "$stage"
setup="$stage/usr/bin/omarchy-mac-setup-system"
unit="$stage/etc/systemd/system/omarchy-wifi-resume-fix.service"
mkdir -p "${unit%/*}"
"$setup" "$stage"
[[ ! -e $unit ]] || fail 'fresh setup uses vendor unit'
grep -q 'enable omarchy-wifi-resume-fix.service' "$CALLS" || fail 'fresh setup enables recovery'
"$setup" "$stage"
printf 'custom service\n' >"$unit"
: >"$CALLS"
"$setup" "$stage"
[[ $(cat "$unit") == 'custom service' && ! -s $CALLS ]] || fail 'custom unit survives setup'
rm "$unit"
ln -s /dev/null "$unit"
"$setup" "$stage"
[[ $(readlink "$unit") == /dev/null && ! -s $CALLS ]] || fail 'mask survives setup'
rm "$unit"
for spec in 'generic 4433' 'qualcomm 4434' 'apple-silicon 0000'; do
  read -r platform wifi <<<"$spec"
  PLATFORM=$platform WIFI_ID=$wifi "$setup" "$stage"
  [[ ! -s $CALLS ]] || fail 'non-Apple and excluded hardware are untouched'
done
rm "$stage/var/lib/omarchy-mac/wifi-configured"
if SYSTEMCTL_STATUS=42 "$setup" "$stage"; then fail 'enable failure must be retryable'; fi
"$setup" "$stage"
pass 'fresh, repeated, overrides, masks and hardware gates'
# Each fresh root: recovery is enabled for BCM4378, BCM4387 and BCM4388 on Apple Silicon only.
for spec in 'apple-silicon 4425 1' 'apple-silicon 4433 1' 'apple-silicon 4434 1' 'apple-silicon 4488 0' \
  'generic 4433 0' 'generic-aarch64 4434 0' 'qualcomm 4434 0'; do
  read -r platform wifi enabled <<<"$spec"
  fresh="$work/fresh-$platform-$wifi"
  "$ROOT/install" "$fresh"
  : >"$CALLS"
  PLATFORM=$platform WIFI_ID=$wifi "$fresh/usr/bin/omarchy-mac-setup-system" "$fresh"
  if (( enabled )); then
    grep -q 'enable omarchy-wifi-resume-fix.service' "$CALLS" || fail "recovery enabled on $platform $wifi"
    [[ -f $fresh/var/lib/omarchy-mac/wifi-configured ]] || fail "recovery setup recorded on $platform $wifi"
  else
    [[ ! -s $CALLS && ! -e $fresh/var/lib/omarchy-mac ]] || fail "recovery left off on $platform $wifi"
  fi
done
# A detector that cannot decide stops setup before it changes anything.
fresh="$work/fresh-contradiction"
"$ROOT/install" "$fresh"
mkdir -p "$fresh/etc/NetworkManager/conf.d"
printf '%s\n' '[device]' 'wifi.backend=iwd' >"$fresh/etc/NetworkManager/conf.d/wifi_backend.conf"
: >"$CALLS"
if PLATFORM_ERROR='contradictory platform identity' "$fresh/usr/bin/omarchy-mac-setup-system" "$fresh" 2>"$work/err"; then
  fail 'a detector failure fails setup'
fi
grep -q 'contradictory platform identity' "$work/err" || fail 'setup reports the detector failure'
[[ -f $fresh/etc/NetworkManager/conf.d/wifi_backend.conf && ! -s $CALLS ]] || fail 'a detector failure changes nothing'
pass 'BCM4378, BCM4387 and BCM4388 on Apple Silicon only, and a detector failure stops setup'
user_setup="$stage/usr/bin/omarchy-mac-setup-user"
export XDG_RUNTIME_DIR="$work/no-session"
unset XDG_CONFIG_HOME XDG_STATE_HOME
for name in alice bob; do
  export HOME="$work/$name"
  policy="$HOME/.config/wireplumber/wireplumber.conf.d/asahi-headset-mic.conf"
  wants="$HOME/.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service"
  : >"$CALLS"
  "$user_setup" "$stage"
  "$user_setup" "$stage"
  [[ -L $wants && ! -s $CALLS && ! -e $policy ]] || fail 'offline setup needs no bus or private policy'
  mkdir -p "${policy%/*}"
  printf 'custom policy\n' >"$policy"
  "$user_setup" "$stage"
  [[ $(cat "$policy") == 'custom policy' ]] || fail 'custom user policy survives'
  rm "$policy"
  ln -s /missing-custom-target "$policy"
  "$user_setup" "$stage"
  [[ -L $policy ]] || fail 'dangling policy override survives'
done
for scope in "$HOME/.config/systemd/user" "$stage/etc/systemd/user"; do
  mkdir -p "$scope"
  rm -f "$wants"
  ln -s /dev/null "$scope/omarchy-asahi-mic.service"
  "$user_setup" "$stage"
  [[ ! -e $wants && ! -L $wants ]] || fail 'user and global masks remain disabled'
  rm "$scope/omarchy-asahi-mic.service"
  echo custom >"$scope/omarchy-asahi-mic.service"
  "$user_setup" "$stage"
  [[ ! -L $wants ]] || fail 'custom user fragment is left alone'
  rm "$scope/omarchy-asahi-mic.service"
done
ln -s /dev/null "$wants"
"$user_setup" "$stage"
[[ $(readlink "$wants") == /dev/null ]] || fail 'activation mask survives'
pass 'multiple users, offline setup, user policies, custom fragments and masks'
# First-session activation and activation failures use a real fake bus socket.
python3 - "$user_setup" "$stage" "$work" <<'PY'
import os, socket, subprocess, sys
from pathlib import Path
setup, stage, work = sys.argv[1:]
# Redirect filesystem paths while exercising the default live-session branch.
script = Path(work)/'session-setup'
script.write_text(Path(setup).read_text().replace('$root/usr/', stage+'/usr/').replace('$root/etc/', stage+'/etc/').replace('$root/run/', stage+'/run/'))
script.chmod(0o755)
setup = str(script)
env = dict(os.environ, HOME=work+'/session', XDG_RUNTIME_DIR=work+'/runtime')
Path(env['XDG_RUNTIME_DIR']).mkdir()
with socket.socket(socket.AF_UNIX) as bus:
    bus.bind(env['XDG_RUNTIME_DIR']+'/bus')
    subprocess.run([setup], env=env, check=True)
    calls = Path(env['CALLS']).read_text()
    assert '--user daemon-reload' in calls and '--user start omarchy-asahi-mic.service' in calls
    result = subprocess.run([setup], env=dict(env, SYSTEMCTL_STATUS='42'))
    assert result.returncode == 42
PY
pass 'first-session activation errors remain retryable'

# An explicit disable after successful setup remains a choice on later runs.
rm "$wants"
"$user_setup" "$stage"
[[ ! -L $wants ]] || fail 'repeat setup preserves disabled microphone service'
: >"$CALLS"
"$setup" "$stage"
[[ ! -s $CALLS ]] || fail 'repeat setup does not reenable disabled Wi-Fi recovery'
pass 'explicit disables survive repeated setup'

[[ -f $stage/usr/share/wireplumber/wireplumber.conf.d/asahi-audio-no-suspend.conf ]] || fail 'the vendor speaker policy ships'
pass 'the vendor speaker no-suspend policy ships'

# The speaker DSP graph keeps running between streams; the mic chains do not.
dsp="$stage/usr/share/pipewire/pipewire.conf.d/asahi-audio-no-suspend.conf"
[[ -f $dsp ]] || fail 'the speaker DSP no-suspend policy ships'
grep -q 'node.always-process = true' "$dsp" || fail 'the speaker DSP graph keeps processing'
mapfile -t patterns < <(sed -n 's/.*node\.name = "~\([^"]*\)".*/\1/p' "$dsp")
(( ${#patterns[@]} == 2 )) || fail 'the DSP policy matches both halves of the speaker chain'
matches() { local name=$1 pattern; for pattern in "${patterns[@]}"; do grep -Eq "$pattern" <<<"$name" && return 0; done; return 1; }
for name in audio_effect.j416-convolver effect_output.j416-convolver audio_effect.mini-convolver effect_output.j274-convolver; do
  matches "$name" || fail "the DSP policy keeps $name running"
done
for name in audio_effect.j413-mic effect_output.j413-mic alsa_output.platform-sound.HiFi__Headphones__sink effect_output.rnnoise; do
  ! matches "$name" || fail "the DSP policy leaves $name alone"
done
pass 'the speaker DSP graph stays running while mic chains still suspend'

# sudo -i clears XDG_RUNTIME_DIR while the owner's session bus still exists at
# /run/user/UID. systemctl --user cannot reach it then, so setup must not try.
python3 - "$user_setup" "$stage" "$work" <<'PY'
import os, socket, subprocess, sys
from pathlib import Path
setup, stage, work = sys.argv[1:]
runtime = Path(work)/'run-user'
runtime.mkdir()
script = Path(work)/'resume-setup'
text = Path(setup).read_text().replace('$root/usr/', stage+'/usr/').replace('$root/etc/', stage+'/etc/').replace('$root/run/', stage+'/run/')
script.write_text(text.replace('/run/user/$UID', str(runtime)))
script.chmod(0o755)
env = {k: v for k, v in os.environ.items() if k != 'XDG_RUNTIME_DIR'}
env['HOME'] = work+'/resume'
Path(env['CALLS']).write_text('')
with socket.socket(socket.AF_UNIX) as bus:
    bus.bind(str(runtime/'bus'))
    subprocess.run([str(script)], env=env, check=True)
    assert '--user' not in Path(env['CALLS']).read_text(), 'no user-bus call without XDG_RUNTIME_DIR'
    assert (Path(env['HOME'])/'.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service').is_symlink()
PY
pass 'user setup skips the user bus when sudo cleared XDG_RUNTIME_DIR'

# Live setup restarts a speakersafetyd left dead by a start-limit, and leaves a
# running or disabled one alone.
mkdir -p "$work/live" "$work/live-bin" "$stage/usr/lib/systemd/system"
touch "$stage/usr/lib/systemd/system/speakersafetyd.service"
sed -e "s|\$root/|$stage/|g" -e "s|-d /run/systemd/system|-d $work/live|" "$setup" >"$work/live-setup"
chmod +x "$work/live-setup"
cat >"$work/live-bin/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "is-enabled --quiet speakersafetyd.service") exit "${SAFETY_ENABLED:-0}" ;;
  "is-active --quiet speakersafetyd.service") exit "${SAFETY_ACTIVE:-0}" ;;
  "start speakersafetyd.service") exit "${SAFETY_START:-0}" ;;
esac
STUB
printf '#!/bin/bash\n' >"$work/live-bin/NetworkManager"
printf '#!/bin/bash\n' >"$work/live-bin/modprobe"
chmod +x "$work/live-bin/"*
live() { : >"$CALLS"; PATH="$work/live-bin:$PATH" "$work/live-setup" 2>"$work/live-errors"; }
SAFETY_ACTIVE=3 live
grep -Fxq 'reset-failed speakersafetyd.service' "$CALLS" && grep -Fxq 'start speakersafetyd.service' "$CALLS" ||
  fail 'a dead speakersafetyd is reset and started' "$(cat "$CALLS")"
live
! grep -Eq '^(reset-failed|start) speakersafetyd' "$CALLS" || fail 'a running speakersafetyd is left alone'
SAFETY_ENABLED=1 SAFETY_ACTIVE=3 live
! grep -Eq '^(reset-failed|start) speakersafetyd' "$CALLS" || fail 'a disabled speakersafetyd is not started'
SAFETY_ACTIVE=3 SAFETY_START=1 live || fail 'a failed start does not fail setup'
grep -Fq 'speakers stay muted' "$work/live-errors" || fail 'a failed start is reported'
pass 'live setup recovers speakersafetyd from a start-limit'
