#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -I - "$ROOT/lib/touchid-pam-keyring-unlocked" "$work" <<'PY'
import os
from pathlib import Path
import pwd
import runpy
import socket
import subprocess
import sys
from types import SimpleNamespace

helper, work = Path(sys.argv[1]), Path(sys.argv[2])
module = runpy.run_path(str(helper))
unlocked = module["unlocked"]
home = work / "home"
home.mkdir()
entry = pwd.getpwuid(os.getuid())
user = pwd.struct_passwd((*entry[:5], str(home), entry.pw_shell))
unlocked.__globals__["pwd"] = SimpleNamespace(getpwnam=lambda name: user)
logins = work / "logins"
unlocked.__globals__["LOGINS"] = logins
runtime = work / "runtime"
bus = runtime / str(user.pw_uid) / "bus"
bus.parent.mkdir(parents=True)
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(bus))

def run(command, **options):
    if "/usr/bin/busctl" in command:
        assert "NameHasOwner" in command, command
        return subprocess.CompletedProcess(command, 0, "b false\n", "")
    # The fixture already runs as its user: exercise the real file lookup without
    # requiring root to call setpriv in CI.
    start = command.index("--reset-env") + 1
    return subprocess.run(command[start:], **options)

failures = []
if unlocked(user.pw_name, run, runtime):
    failures.append("a lingering bus without a prior login allowed fingerprints")
assert module["record_login"](user.pw_name), "SDDM reaching open_session records the login"
assert module["record_login"](user.pw_name), "recording the same login is idempotent"
assert unlocked(user.pw_name, run, runtime), "a prior login with no keyring allows re-login"
marker = logins / str(user.pw_uid)
marker.chmod(0o666)
assert not unlocked(user.pw_name, run, runtime), "a user-writable marker is not proof"
marker.chmod(0o600)
marker.unlink()
marker.symlink_to(home)
assert not unlocked(user.pw_name, run, runtime), "a symlink is not login proof"
assert not module["record_login"](user.pw_name), "recording does not follow a forged marker"
marker.unlink()
assert module["record_login"](user.pw_name)
private = home / ".local"
(private / "share/keyrings").mkdir(parents=True)
(private / "share/keyrings/login.keyring").touch()
private.chmod(0)
try:
    if unlocked(user.pw_name, run, runtime):
        failures.append("an inaccessible parent hid a login keyring")
finally:
    private.chmod(0o700)
for name in module["LOGIN_FILES"]:
    key = home / name
    key.parent.mkdir(parents=True, exist_ok=True)
    key.touch()
    assert not unlocked(user.pw_name, run, runtime), f"{name} is not missed"
    key.parent.chmod(0)
    try:
        assert not unlocked(user.pw_name, run, runtime), f"an inaccessible {name} refuses"
    finally:
        key.parent.chmod(0o700)
    key.unlink()
assert unlocked(user.pw_name, run, runtime), "confirmed absence allows re-login"
marker.unlink()
assert not unlocked(user.pw_name, run, runtime), "a fresh boot with no marker refuses"
listener.close()
assert not failures, "; ".join(failures)
print("ok - a lingering bus needs trusted boot-local login proof and file lookups distinguish absence from errors")
PY
