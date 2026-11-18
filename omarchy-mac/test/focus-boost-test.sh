#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
"$ROOT/install" "$stage"
unit="$stage/usr/lib/systemd/system/omarchy-mac-focus-boost.service"
[[ -x $stage/usr/bin/omarchy-mac-focus-boost && -f $unit ]] || fail 'stages the command and unit'
grep -Fxq 'ConditionFirmware=device-tree-compatible(apple,j616c)' "$unit" || fail 'the unit runs on the J616C only'
grep -Fxq 'ExecCondition=/usr/bin/omarchy-hw-apple-silicon' "$unit" || fail 'the unit stays behind the platform detector'
[[ -L ${unit%/*}/multi-user.target.wants/omarchy-mac-focus-boost.service ]] || fail 'the vendor wants link enables the unit'
pass 'stages a focus boost service gated to the J616C'

fixture="$work/omarchy_mac_focus_boost.py"
sed -e "s|/run/user/\*/hypr|$work/run/user/*/hypr|" -e "s|/sys/fs/cgroup|$work/cgroup|" \
  -e "s|/proc/bus/input/devices|$work/input-devices|" -e "s|\"/dev/input\"|\"$work/input\"|" \
  -e "s|\"/proc\"|\"$work/proc\"|" \
  "$ROOT/bin/omarchy-mac-focus-boost" >"$fixture"
mkdir -p "$work/run/user/1000/hypr/old" "$work/run/user/1000/hypr/new"
: >"$work/run/user/1000/hypr/old/.socket2.sock"
: >"$work/run/user/1000/hypr/new/.socket2.sock"
touch -d '2000-01-01' "$work/run/user/1000/hypr/old/.socket2.sock"
apps="$work/cgroup/user.slice/app.slice"
mkdir -p "$apps/app-flatpak-browser-11.scope" "$apps/app-flatpak-browser-2a.scope" "$apps/app-other-1.scope" "$apps/plain.service"
printf '10\n11\n' >"$apps/app-flatpak-browser-11.scope/cgroup.procs"
printf '12\n' >"$apps/app-flatpak-browser-2a.scope/cgroup.procs"
printf '20\n' >"$apps/app-other-1.scope/cgroup.procs"
printf '13\n' >>"$apps/app-flatpak-browser-2a.scope/cgroup.procs"
printf 'usage_usec 1500\nuser_usec 1000\n' >"$apps/app-flatpak-browser-11.scope/cpu.stat"
printf 'usage_usec 500\nuser_usec 100\n' >"$apps/app-flatpak-browser-2a.scope/cpu.stat"
# Processes 10 to 12 and 20 are the session owner's; 13 shares the browser's scope but belongs to someone else, as does 30.
for pid in 10 11 12 13 20 30; do
  mkdir -p "$work/proc/$pid"
  owner=$(id -u)
  [[ $pid == 13 || $pid == 30 ]] && owner=$((owner + 1))
  printf 'Name:\tapp\nUid:\t%s\t%s\t%s\t%s\n' "$owner" "$owner" "$owner" "$owner" >"$work/proc/$pid/status"
done
printf 'Uid:\t%s\t0\t0\t0\n' "$(id -u)" >"$work/proc/12/status.setuid"
printf '0::/user.slice/app.slice/app-flatpak-browser-11.scope\n' >"$work/proc/10/cgroup"
printf '0::/user.slice/app.slice/app-other-1.scope\n' >"$work/proc/20/cgroup"
printf '0::/user.slice/app.slice/app-other-1.scope\n' >"$work/proc/30/cgroup"
cat >"$work/input-devices" <<'DEVICES'
I: Bus=0003
N: Name="Apple Internal Keyboard / Trackpad"
H: Handlers=sysrq kbd leds event3

I: Bus=0019
N: Name="Lid Switch"
H: Handlers=event1

I: Bus=0019
N: Name="Headphone Jack"
H: Handlers=event2

I: Bus=0003
N: Name="USB Mouse"
H: Handlers=mouse0 event7
DEVICES
python3 -I - "$work" <<'PY'
import importlib.util
import os
import sys
work = sys.argv[1]
spec = importlib.util.spec_from_file_location("focus", f"{work}/omarchy_mac_focus_boost.py")
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)

assert focus.session() == (os.getuid(), f"{work}/run/user/1000/hypr/new"), "takes the newest session"
assert focus.input_devices() == {f"{work}/input/event3", f"{work}/input/event7"}, "keyboards and mice only"
parent = "/user.slice/app.slice"
siblings = focus.app_cgroups(f"{parent}/app-flatpak-browser-11.scope")
assert siblings == [f"{parent}/app-flatpak-browser-11.scope", f"{parent}/app-flatpak-browser-2a.scope"], siblings
assert focus.app_cgroups(f"{parent}/plain.service") == [f"{parent}/plain.service"], "a plain unit stands alone"
assert focus.app_cgroups(None) == [], "no cgroup means no app"
assert focus.app_pids(siblings) == {10, 11, 12, 13}, "every process of the app"
assert focus.owned(10, os.getuid()) and not focus.owned(13, os.getuid()), "another user's process is not the owner's"
assert not focus.owned(99, os.getuid()), "a process that is gone is nobody's"
os.rename(f"{work}/proc/12/status", f"{work}/proc/12/status.real")
os.rename(f"{work}/proc/12/status.setuid", f"{work}/proc/12/status")
assert not focus.owned(12, os.getuid()), "a setuid process runs as someone else"
os.rename(f"{work}/proc/12/status", f"{work}/proc/12/status.setuid")
os.rename(f"{work}/proc/12/status.real", f"{work}/proc/12/status")
assert focus.split_events(b"activewindow", b"v2>>a\nfullscr") == ([b"activewindowv2>>a"], b"fullscr"), "joins split lines"
lines, rest = focus.split_events(b"", b"x" * (focus.EVENT_LINE_BYTES + 1))
assert (lines, rest) == ([], None), "an endless line is not kept"
assert focus.split_events(None, b"x" * 100) == ([], None), "and is skipped to its end"
assert focus.split_events(None, b"xx\nclosewindow>>a\n") == ([b"closewindow>>a"], b""), "the next line counts again"
assert focus.app_pids([f"{parent}/gone.scope"]) == set(), "a closed app has no processes"
assert focus.app_cpu_usec(siblings) == 2000, "CPU time of the whole app"
PY
pass 'follows the newest session, the input devices and every cgroup of the app'

python3 -I - "$work" <<'PY'
import importlib.util
import os
import socket
import sys
import threading
import time
work = sys.argv[1]
spec = importlib.util.spec_from_file_location("focus", f"{work}/omarchy_mac_focus_boost.py")
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)
focus.REPLY_SECONDS = 0.5


def listen(path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen()
    return server


def serve(server, reply):
    def loop():
        while True:
            connection, _ = server.accept()
            connection.recv(64)
            reply(connection)
    threading.Thread(target=loop, daemon=True).start()


def endless(connection):
    try:
        while True:
            connection.sendall(b"x" * 65536)
    except OSError:
        connection.close()


for name, reply in (("endless", endless), ("silent", lambda connection: None)):
    os.makedirs(f"{work}/{name}")
    serve(listen(f"{work}/{name}/.socket.sock"), reply)
    started = time.monotonic()
    assert focus.focused(f"{work}/{name}") == (None, False), f"a {name} reply names no window"
    assert time.monotonic() - started < 2, f"a {name} reply is cut off in time"
assert focus.focused(f"{work}/missing") == (None, False), "no socket names no window"
PY
pass 'bounds what it reads from the session sockets'

python3 -I - "$work" <<'PY'
import importlib.util
import json
import os
import signal
import socket
import sys
import threading
import time
work = sys.argv[1]
spec = importlib.util.spec_from_file_location("focus", f"{work}/omarchy_mac_focus_boost.py")
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)
# With no rescan due for a minute, only a fresh scan on the switch boosts the next app.
focus.RESCAN_SECONDS = 60.0
boost = focus.BOOST
directory = f"{work}/session"
os.makedirs(directory)
focused = {"pid": 10}
calls = []
changed = threading.Condition()


def record(pid, value):
    with changed:
        calls.append((pid, value))
        changed.notify_all()


def wait_for(expected):
    deadline = time.monotonic() + 1.5
    with changed:
        while not all(calls.count(call) >= count for call, count in expected.items()):
            if not changed.wait(deadline - time.monotonic()) and time.monotonic() >= deadline:
                return False
    return True


focus.uclampset = record
focus.user_pids = lambda uid: set()
requests = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
requests.bind(f"{directory}/.socket.sock")
requests.listen()
events = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
events.bind(f"{directory}/.socket2.sock")
events.listen()


def answer():
    while True:
        connection, _ = requests.accept()
        with connection:
            connection.recv(64)
            connection.sendall(json.dumps({"pid": focused["pid"], "fullscreen": 0}).encode())


steps = {}


def drive():
    stream, _ = events.accept()
    try:
        steps["first app"] = wait_for({(10, boost): 1, (11, boost): 1, (12, boost): 1})
        focused["pid"] = 20
        stream.sendall(b"activewindowv2>>a\n")
        steps["switch"] = wait_for({(10, 0): 1, (11, 0): 1, (12, 0): 1, (20, boost): 1})
        focused["pid"] = 30
        stream.sendall(b"activewindowv2>>b\n")
        steps["someone else's window"] = wait_for({(20, 0): 1})
        focused["pid"] = 20
        stream.sendall(b"activewindowv2>>a\n")
        steps["switch back"] = wait_for({(20, boost): 2})
    finally:
        os.kill(os.getpid(), signal.SIGTERM)


threading.Thread(target=answer, daemon=True).start()
threading.Thread(target=drive, daemon=True).start()
focus.stop_on_signals()
try:
    focus.run(os.getuid(), directory)
except SystemExit:
    pass
for step, done in steps.items():
    assert done, f"{step}: {calls}"
assert len(steps) == 4, steps
assert calls.count((20, 0)) == 2, f"stopping resets the boosted app: {calls}"
assert not any(pid in (13, 30) for pid, value in calls), f"another user's processes stay untouched: {calls}"
PY
pass 'moves the boost between apps at once, never to another user, and takes it back on stop'
