#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH"
export OMARCHY_MAC_TOUCHID_PAM=$work/pam
mkdir "$OMARCHY_MAC_TOUCHID_PAM"
helper=$ROOT/lib/touchid-sddm

python3 -I "$helper" enable
[[ -z $(ls -A "$OMARCHY_MAC_TOUCHID_PAM") ]] || fail 'no SDDM means no PAM changes'
cat >"$work/original" <<'PAM'
#%PAM-1.0
auth include system-login
-auth optional pam_gnome_keyring.so
account include system-login
password include system-login
session include system-login
PAM
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
cat >"$OMARCHY_MAC_TOUCHID_PAM/system-login" <<'PAM'
auth required pam_shells.so
auth requisite pam_nologin.so
auth include system-auth
account required pam_access.so
PAM
cat >"$OMARCHY_MAC_TOUCHID_PAM/system-auth" <<'PAM'
auth required pam_faillock.so preauth
-auth [success=2 default=ignore] pam_systemd_home.so
auth [success=1 default=bad] pam_unix.so try_first_pass nullok
auth [default=die] pam_faillock.so authfail
auth optional pam_permit.so
auth required pam_env.so
auth required pam_faillock.so authsucc
PAM
python3 -I "$helper" enable
cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/enabled"
python3 -I "$helper" enable
cmp "$work/enabled" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'enabling twice changes nothing'
python3 -I "$helper" disable
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling restores the exact original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the owned include is removed'
python3 -I "$helper" disable
pass 'SDDM enablement is optional, idempotent and reversible'

sed 's/$/\r/' "$work/original" >"$work/crlf"
cp "$work/crlf" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" enable
python3 -I "$helper" disable
cmp "$work/crlf" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling must preserve original line endings'
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
pass 'SDDM removal preserves the original line endings'

cp "$OMARCHY_MAC_TOUCHID_PAM/system-login" "$work/system-login"
printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/system-login"
! python3 -I "$helper" enable 2>"$work/error" || fail 'an inherited mandatory auth rule must not be bypassed'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'inherited policy refusal changed SDDM'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'inherited policy refusal installed a policy'
cp "$work/system-login" "$OMARCHY_MAC_TOUCHID_PAM/system-login"
cp "$OMARCHY_MAC_TOUCHID_PAM/system-auth" "$work/system-auth"
printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/system-auth"
! python3 -I "$helper" enable 2>"$work/error" || fail 'a custom system-auth rule must not be bypassed'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'custom system-auth refusal changed SDDM'
cp "$work/system-auth" "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
pass 'inherited authentication requirements are preserved'

for name in sddm system-login system-auth; do
  cp "$OMARCHY_MAC_TOUCHID_PAM/$name" "$work/case-original"
  for kind in AUTH Auth -AUTH --auth not-a-pam-type; do
    printf '%s required pam_deny.so\n' "$kind" >>"$OMARCHY_MAC_TOUCHID_PAM/$name"
    cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/case-sddm"
    cp "$OMARCHY_MAC_TOUCHID_PAM/$name" "$work/case-source"
    ! python3 -I "$helper" enable 2>"$work/error" || fail 'case-variant authentication rules must be refused'
    cmp "$work/case-sddm" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'case-variant refusal changed SDDM'
    cmp "$work/case-source" "$OMARCHY_MAC_TOUCHID_PAM/$name" || fail 'case-variant refusal changed the source policy'
    [[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'case-variant refusal installed a policy'
    cp "$work/case-original" "$OMARCHY_MAC_TOUCHID_PAM/$name"
  done
done
pass 'case-variant authentication rules are refused without writes'

printf 'auth required pam_deny.so\n' >>"$OMARCHY_MAC_TOUCHID_PAM/sddm"
cp "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/custom"
! python3 -I "$helper" enable 2>"$work/error" || fail 'custom auth rules must be preserved'
cmp "$work/custom" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'a refusal modified custom PAM'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'a refusal installed a policy'
rm "$OMARCHY_MAC_TOUCHID_PAM/sddm"
ln -s "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
! python3 -I "$helper" enable 2>"$work/error" || fail 'a symlink must be refused'
rm "$OMARCHY_MAC_TOUCHID_PAM/sddm"
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
printf 'administrator policy\n' >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
! python3 -I "$helper" enable 2>"$work/error" || fail 'an administrator policy must be preserved'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'a refusal enabled custom policy'
pass 'custom and symlinked PAM files are refused before writes'

previous=$(python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["PREVIOUS_POLICIES"][0], end="")' "$helper")
printf '%s\n' "$previous" >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
printf '# omarchy-mac Touch ID\nauth include omarchy-mac-touchid\n' | cat - "$work/original" >"$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" enable
current=$(python3 -I -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["POLICY"], end="")' "$helper")
[[ $(<"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid") == "$current" ]] || fail 'enabling replaces the previous owned policy'
python3 -I "$helper" disable
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling after an upgrade restores the original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the upgraded policy is removed'
printf '%s\n' "$previous" >"$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid"
python3 -I "$helper" disable
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'a previous owned policy is removed on disable'
pass 'the previous owned policy is upgraded and removed'

# Omarchy rewrites the faillock lines in system-auth; the policy carries its limits.
cp "$OMARCHY_MAC_TOUCHID_PAM/system-auth" "$work/stock-system-auth"
cat >"$OMARCHY_MAC_TOUCHID_PAM/system-auth" <<'PAM'
auth required pam_faillock.so preauth silent deny=10 unlock_time=120
-auth [success=2 default=ignore] pam_systemd_home.so
auth [success=1 default=bad] pam_unix.so try_first_pass nullok
auth [default=die] pam_faillock.so authfail deny=10 unlock_time=120
auth optional pam_permit.so
auth required pam_env.so
auth required pam_faillock.so authsucc
PAM
python3 -I "$helper" enable || fail "Omarchy's lockout options must not make system-auth custom"
grep -Fxq 'auth requisite pam_faillock.so preauth silent deny=10 unlock_time=120' "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" &&
  grep -Fxq 'auth [default=die] pam_faillock.so authfail deny=10 unlock_time=120' "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" ||
  fail "the policy must use system-auth's lockout options"
cp "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" "$work/omarchy-policy"
python3 -I "$helper" enable
cmp "$work/omarchy-policy" "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" || fail 'enabling twice keeps the same lockout options'
cp "$work/stock-system-auth" "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
python3 -I "$helper" disable || fail 'an owned policy with earlier lockout options is still ours to remove'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling after the options changed restores the original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the owned policy is removed whatever its lockout options'
sed -i 's/^auth required pam_faillock.so preauth$/& dir=\/tmp\/lock/' "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
! python3 -I "$helper" enable 2>"$work/error" || fail 'an unknown lockout option is custom policy and must be refused'
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'refusing an unknown lockout option changed SDDM'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'refusing an unknown lockout option installed a policy'
cp "$work/stock-system-auth" "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
pass "Omarchy's lockout options are accepted and carried into the policy"

# A policy from before authsucc, with Omarchy's options, is still ours: enable replaces it.
sed -e 's/^auth required pam_faillock.so preauth$/& silent deny=10 unlock_time=120/' \
  -e 's/^auth \[default=die\] pam_faillock.so authfail$/& deny=10 unlock_time=120/' \
  -e 's/^auth required pam_faillock.so authsucc$/& deny=10/' "$work/stock-system-auth" >"$OMARCHY_MAC_TOUCHID_PAM/system-auth"
python3 -I - "$helper" "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" <<'PY'
import runpy, sys
module = runpy.run_path(sys.argv[1])
old = module["render_policy"](["silent", "deny=10", "unlock_time=120"], ["deny=10", "unlock_time=120"], [],
                               module["PREVIOUS_TEMPLATES"][0])
assert "authsucc" not in old
open(sys.argv[2], "w").write(old)
PY
printf '# omarchy-mac Touch ID\nauth include omarchy-mac-touchid\n' | cat - "$work/original" >"$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" enable || fail 'a policy from before authsucc is ours to replace'
grep -Fxq 'auth [success=done default=die] pam_faillock.so authsucc deny=10' "$OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid" ||
  fail "the replaced policy clears failures with system-auth's options"
python3 -I "$helper" disable
cmp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm" || fail 'disabling after replacing a pre-authsucc policy restores the original'
[[ ! -e $OMARCHY_MAC_TOUCHID_PAM/omarchy-mac-touchid ]] || fail 'the replaced policy is removed'
cp "$work/stock-system-auth" "$OMARCHY_MAC_TOUCHID_PAM/system-auth"
pass 'a policy from before authsucc is replaced and removed'

# Removal only cares whether SDDM's file includes our policy, even through a symlink.
mv "$OMARCHY_MAC_TOUCHID_PAM/sddm" "$work/real-sddm"
ln -s "$work/real-sddm" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" disable || fail 'a symlinked SDDM file that does not include the policy has nothing to remove'
[[ -L $OMARCHY_MAC_TOUCHID_PAM/sddm ]] && cmp "$work/original" "$work/real-sddm" || fail 'removal changed a symlinked SDDM file'
ln -sfn "$work/missing" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
python3 -I "$helper" disable || fail 'a dangling SDDM symlink has nothing to remove'
ln -sfn "$work/real-sddm" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
printf '# omarchy-mac Touch ID\nauth include omarchy-mac-touchid\n' | cat - "$work/original" >"$work/real-sddm"
cp "$work/real-sddm" "$work/included"
! python3 -I "$helper" disable 2>"$work/error" || fail 'a symlinked SDDM file that includes the policy must be reported'
cmp "$work/included" "$work/real-sddm" || fail 'a refused removal changed the symlink target'
rm "$OMARCHY_MAC_TOUCHID_PAM/sddm"
cp "$work/original" "$OMARCHY_MAC_TOUCHID_PAM/sddm"
pass 'removal ignores SDDM files that do not include the policy and reports ones that do'

# Exercise the generated control flow with libpam and the real empty-password
# helper through pam_exec, substituting only the keyring, fingerprint and
# password providers' results.
python3 -I - "$helper" "$work" "$ROOT/lib" <<'PY'
import ctypes
import ctypes.util
from pathlib import Path
import runpy
import sys

helper, work, lib = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
root = work / "dispatch"
root.mkdir()
policy = runpy.run_path(str(helper))["POLICY"]
library = ctypes.util.find_library("pam")
if library is None:
    raise RuntimeError("libpam is required for the PAM dispatch test")
pam = ctypes.CDLL(library)
libc = ctypes.CDLL(ctypes.util.find_library("c"))
libc.malloc.restype = ctypes.c_void_p
libc.strdup.restype = ctypes.c_void_p
libc.strdup.argtypes = [ctypes.c_char_p]
pointer = ctypes.c_void_p

class Message(ctypes.Structure):
    _fields_ = [("style", ctypes.c_int), ("text", ctypes.c_char_p)]

class Response(ctypes.Structure):
    _fields_ = [("text", pointer), ("code", ctypes.c_int)]

CONVERSE = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int,
                            ctypes.POINTER(ctypes.POINTER(Message)),
                            ctypes.POINTER(ctypes.POINTER(Response)), pointer)

class Conversation(ctypes.Structure):
    _fields_ = [("function", CONVERSE), ("data", pointer)]

pam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                 ctypes.POINTER(Conversation), ctypes.c_char_p,
                                 ctypes.POINTER(pointer)]
pam.pam_authenticate.argtypes = [pointer, ctypes.c_int]
pam.pam_acct_mgmt.argtypes = [pointer, ctypes.c_int]
pam.pam_end.argtypes = [pointer, ctypes.c_int]

def script(name, body):
    path = work / name
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(0o755)
    return path

record = work / "authfail-record"
cleared = work / "authsucc-record"
# pam_exec passes no PATH, so point the real helper's platform check at the stub.
empty = script("empty-password", (lib / "touchid-pam-empty-password").read_text().removeprefix("#!/bin/bash\n")
               .replace("omarchy-hw-apple-silicon", str(work / "bin" / "omarchy-hw-apple-silicon")))
keyring = {True: script("keyring-unlocked", "exit 0\n"),
           False: script("keyring-locked", "exit 1\n")}
authfail = script("authfail", f"echo >>{record}\nexit 0\n")
authsucc = script("authsucc", f"echo >>{cleared}\nexit 0\n")
check = script("password-check", "IFS= read -r -d '' typed || true\n"
               "if [[ $typed == secret ]]; then exit 0; else exit 1; fi\n")

def attempt(typed, unlocked, fingerprint, password=True, shell=True, nologin=True,
            lockout=True, account=True):
    current = policy.replace("/usr/lib/omarchy-mac/touchid-pam-empty-password", str(empty))
    current = current.replace("/usr/lib/omarchy-mac/touchid-pam-keyring-unlocked",
                              str(keyring[unlocked]))
    current = current.replace("pam_fprintd.so max-tries=3 timeout=5",
                              f"pam_debug.so auth={fingerprint}")
    current = current.replace("pam_faillock.so authfail", f"pam_exec.so {authfail}")
    current = current.replace("pam_faillock.so authsucc", f"pam_exec.so {authsucc}")
    for module, result in (("pam_shells.so", shell), ("pam_nologin.so", nologin),
                           ("pam_faillock.so preauth", lockout)):
        current = current.replace(module, "pam_permit.so" if result else "pam_deny.so")
    (root / "omarchy-mac-touchid").write_text(current)
    stack = (f"auth required pam_exec.so expose_authtok {check}\n" if password
             else "auth required pam_deny.so\n")
    (root / "sddm").write_text(
        "auth include omarchy-mac-touchid\n" + stack +
        "account required " + ("pam_permit.so" if account else "pam_deny.so") + "\n")
    record.unlink(missing_ok=True)
    cleared.unlink(missing_ok=True)
    prompts = []

    def converse(count, messages, responses, data):
        answers = ctypes.cast(libc.malloc(ctypes.sizeof(Response) * count),
                              ctypes.POINTER(Response))
        for index in range(count):
            message = messages[index].contents if count == 1 else messages[0][index]
            answers[index].code = 0
            answers[index].text = None
            if message.style == 1:
                prompts.append(message.text)
                answers[index].text = libc.strdup(typed.encode())
        responses[0] = answers
        return 0

    function = CONVERSE(converse)
    conversation = Conversation(function, None)
    handle = pointer()
    result = pam.pam_start_confdir(b"sddm", b"fixture-user", ctypes.byref(conversation),
                                  str(root).encode(), ctypes.byref(handle))
    if result != 0:
        raise RuntimeError(f"pam_start_confdir: {result}")
    try:
        result = pam.pam_authenticate(handle, 0)
        if result == 0:
            result = pam.pam_acct_mgmt(handle, 0)
    finally:
        pam.pam_end(handle, result)
    return result == 0, len(prompts), record.exists(), cleared.exists()

# (succeeds, prompts, failure counted, failures cleared)
cases = (
    (dict(typed="", unlocked=True, fingerprint="success"), (True, 1, False, True)),
    (dict(typed="", unlocked=True, fingerprint="authinfo_unavail"), (False, 1, False, False)),
    (dict(typed="", unlocked=True, fingerprint="auth_err"), (False, 1, False, False)),
    (dict(typed="", unlocked=True, fingerprint="maxtries"), (False, 1, True, False)),
    (dict(typed="", unlocked=False, fingerprint="success"), (False, 1, False, False)),
    (dict(typed="", unlocked=True, fingerprint="authinfo_unavail", password=True), (False, 1, False, False)),
    (dict(typed="secret", unlocked=True, fingerprint="success", password=False), (False, 1, False, False)),
    (dict(typed="secret", unlocked=False, fingerprint="maxtries"), (True, 1, False, False)),
    (dict(typed="wrong", unlocked=True, fingerprint="success"), (False, 1, False, False)),
    (dict(typed="", unlocked=True, fingerprint="success", shell=False), (False, 0, False, False)),
    (dict(typed="", unlocked=True, fingerprint="success", nologin=False), (False, 0, False, False)),
    (dict(typed="", unlocked=True, fingerprint="success", lockout=False), (False, 0, False, False)),
    (dict(typed="secret", unlocked=True, fingerprint="success", lockout=False), (False, 0, False, False)),
    (dict(typed="", unlocked=True, fingerprint="success", account=False), (False, 1, False, True)),
)
for arguments, expected in cases:
    observed = attempt(**arguments)
    assert observed == expected, (arguments, expected, observed)
print("ok - real PAM sends empty passwords to Touch ID only with an unlocked keyring, clears the failure count after an accepted finger, sends typed passwords straight to the password stack with one prompt, and keeps shell, nologin, lockout and account checks")
PY

# The keyring check never starts a stopped keyring and refuses only a login keyring that is or would start locked.
python3 -I - "$ROOT/lib/touchid-pam-keyring-unlocked" "$work" <<'PY'
import os
from pathlib import Path
import pwd
import runpy
import socket
import subprocess
import sys

module = runpy.run_path(sys.argv[1])
unlocked = module["unlocked"]
runtime = Path(sys.argv[2]) / "runtime"
user = pwd.getpwuid(os.getuid())
bus = runtime / str(user.pw_uid) / "bus"

LOGIN = '"/org/freedesktop/secrets/collection/login"'
DEFAULT = '"/org/freedesktop/secrets/collection/Default_5fkeyring"'
SESSION = '"/org/freedesktop/secrets/collection/session"'
xdg_file = Path(user.pw_dir) / ".local/share/keyrings/login.keyring"
legacy_file = Path(user.pw_dir) / ".gnome2/keyrings/login.keyring"

def fake(owner, locked, collections=(LOGIN, SESSION), login_file_exists=False, failure=None):
    # login_file_exists: whether any of the two login keyring files exists
    calls = []

    def run(command, **options):
        calls.append(command)
        assert command[:2] == ["/usr/bin/setpriv", f"--reuid={user.pw_uid}"], command
        if failure:
            raise failure
        if "/usr/bin/test" in command:
            assert command[command.index("/usr/bin/test") + 1:] == [
                "!", "-e", str(xdg_file), "-a", "!", "-e", str(legacy_file)], command
            return subprocess.CompletedProcess(command, 1 if login_file_exists else 0)
        assert f"--address=unix:path={bus}" in command, command
        if "NameHasOwner" in command:
            return subprocess.CompletedProcess(command, 0, f"b {owner}\n", "")
        if "Collections" in command:
            listed = " ".join(("ao", str(len(collections)), *collections))
            return subprocess.CompletedProcess(command, 0, listed + "\n", "")
        assert "Locked" in command and "/org/freedesktop/secrets/collection/login" in command, command
        return subprocess.CompletedProcess(command, 0, f"b {locked}\n", "")
    return run, calls

run, calls = fake("true", "false")
assert not unlocked(user.pw_name, run, runtime) and not calls, "no user bus means locked"
bus.parent.mkdir(parents=True)
listener = socket.socket(socket.AF_UNIX)
listener.bind(str(bus))
assert unlocked(user.pw_name, run, runtime) and len(calls) == 3, "an unlocked login collection"
run, calls = fake("true", "true")
assert not unlocked(user.pw_name, run, runtime), "a locked login collection"
run, calls = fake("true", "true", collections=(DEFAULT, SESSION))
assert unlocked(user.pw_name, run, runtime) and len(calls) == 3, "omacom/omarchy's keyring has no login collection to unlock"
run, calls = fake("true", "true", collections=(DEFAULT, SESSION), login_file_exists=True)
assert not unlocked(user.pw_name, run, runtime), "a running keyring that omits a login keyring file on disk is not taken as empty"
run, calls = fake("true", "false", collections=(DEFAULT, SESSION), failure=OSError("setpriv"))
assert not unlocked(user.pw_name, run, runtime), "an unverifiable disk check refuses"
run, calls = fake("false", "true")
assert unlocked(user.pw_name, run, runtime) and len(calls) == 2, "a stopped keyring without a login keyring file"
assert not any("Locked" in call or "Collections" in call for call in calls), "a stopped keyring is never queried"
run, calls = fake("false", "false", login_file_exists=True)
assert not unlocked(user.pw_name, run, runtime), "a stopped keyring with a login keyring would start locked"

def present_only(path):
    # The fake test command answers for the two real paths: only `path` exists.
    def run(command, **options):
        if "/usr/bin/test" in command:
            tail = command[command.index("/usr/bin/test") + 1:]
            exists = [str(xdg_file), str(legacy_file)][1 if path == "legacy" else 0]
            return subprocess.CompletedProcess(command, 1 if exists in tail else 0)
        return subprocess.CompletedProcess(command, 0, "b false\n", "")
    return run
assert not unlocked(user.pw_name, present_only("legacy"), runtime), "a legacy login keyring is not missed"
assert not unlocked(user.pw_name, present_only("xdg"), runtime), "an XDG login keyring is not missed"
run, calls = fake("true", "false", failure=subprocess.TimeoutExpired("busctl", 5))
assert not unlocked(user.pw_name, run, runtime)
run, calls = fake("false", "false", failure=OSError("setpriv"))
assert not unlocked(user.pw_name, run, runtime)

def broken(command, **options):
    if "NameHasOwner" in command:
        return subprocess.CompletedProcess(command, 0, "b true\n", "")
    return subprocess.CompletedProcess(command, 1, "", "Object does not exist")
assert not unlocked(user.pw_name, broken, runtime), "an unreadable collection list is not taken as empty"
assert not unlocked("no-such-user-omarchy-mac", run, runtime)
print("ok - the keyring check refuses a locked or would-be-locked login keyring and passes a keyring without one")
PY
