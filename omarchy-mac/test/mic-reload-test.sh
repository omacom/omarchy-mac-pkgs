#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
watcher=
cleanup() {
  [[ -z $watcher ]] || kill "$watcher" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/run" "$work/state"
printf '#!/bin/bash\necho "${PLATFORM:-aarch64-apple}"\n' >"$work/bin/omarchy-hw-platform"
stub_apple_predicate "$work/bin"
# The subscriber records its PID and waits; nothing else answers.
cat >"$work/bin/pactl" <<'STUB'
#!/bin/bash
[[ $1 == "subscribe" ]] || exit 1
echo $$ >"$WORK/subscriber"
exec sleep 60
STUB
chmod +x "$work/bin/"*

# A package upgrade replaces the running watcher's file: the watcher runs the
# new file under its own PID with its arguments, and stops its subscriber.
"$ROOT"/install "$work/root"
mapper=$work/root/usr/bin/omarchy-audio-asahi-mic-map
# The host's pacman lock and audio session stay out of it.
cat >"$work/watch.py" <<'WATCH'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader('mapper', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mapper = importlib.util.module_from_spec(spec); loader.exec_module(mapper)
mapper.PACMAN_LOCK = Path(sys.argv[2])
mapper.AUDIO_FILES = ()
sys.argv = [sys.argv[1], '--watch']
sys.exit(mapper.main())
WATCH
env -u PULSE_SERVER -u PIPEWIRE_REMOTE WORK="$work" PATH="$work/bin:$PATH" XDG_RUNTIME_DIR="$work/run" XDG_STATE_HOME="$work/state" \
  python3 "$work/watch.py" "$mapper" "$work/db.lck" 2>"$work/log" &
watcher=$!
for _ in $(seq 100); do
  [[ -s $work/subscriber ]] && break
  sleep 0.1
done
subscriber=$(<"$work/subscriber")
printf '#!/bin/bash\necho "$$ $*" >"$WORK/reloaded"\nexec sleep 60\n' >"$work/new"
chmod +x "$work/new"
mv "$work/new" "$mapper"
for _ in $(seq 200); do
  [[ -s $work/reloaded ]] && break
  sleep 0.1
done
[[ $(<"$work/reloaded") == "$watcher --watch" ]] || fail 'the watcher runs its replaced file in place' "$(cat "$work/log")"
! kill -0 "$subscriber" 2>/dev/null || fail 'the old subscriber stops with the old code'
grep -q 'Running the updated microphone mapper' "$work/log" || fail 'the reload is logged'
pass 'a running watcher runs its upgraded program in place within seconds'
