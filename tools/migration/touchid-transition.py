#!/usr/bin/python3
"""Apply or undo a reviewed Touch ID configuration transition; never alter enrollment."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import tempfile

PREFIXES = (
    "/etc/pam.d/",
    "/etc/systemd/system/",
    "/usr/lib/systemd/system/",
    "/etc/modprobe.d/",
    "/etc/omarchy-mac/",
)
# Installed by omarchy-mac. It prints one JSON readiness object and exits 0.
RECOVERY_REPORT = "/usr/lib/omarchy-mac/touchid-recovery"


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def path_at(root, name):
    require(name.startswith(PREFIXES), "path outside the configuration transition")
    require(str(Path(name)) == name, "noncanonical path")
    relative = Path(name.lstrip("/"))
    require(".." not in relative.parts, "parent traversal")
    path = root / relative
    for parent in reversed(path.parents):
        if parent == root or root in parent.parents:
            if parent.exists() or parent.is_symlink():
                require(stat.S_ISDIR(parent.lstat().st_mode), "non-directory parent")
    return path


def snapshot(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"kind": "absent"}
    row = dict(mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if stat.S_ISLNK(info.st_mode):
        return dict(row, kind="symlink", target=os.readlink(path))
    require(stat.S_ISREG(info.st_mode), "unexpected nonregular configuration")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        require(stat.S_ISREG(opened.st_mode), "changed file type")
        require(
            (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
            == (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, opened.st_gid),
            "changed inode or metadata",
        )
        data = stream.read(1024 * 1024 + 1)
        after = os.fstat(stream.fileno())
        require(
            (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns, opened.st_mode, opened.st_uid, opened.st_gid)
            == (after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_mode, after.st_uid, after.st_gid),
            "file changed during read",
        )
    require(len(data) <= 1024 * 1024, "oversized configuration")
    return dict(
        row,
        kind="file",
        sha256=hashlib.sha256(data).hexdigest(),
        data=base64.b64encode(data).decode(),
    )


def validate_plan(plan):
    require(isinstance(plan, dict) and plan.get("schema") == 1, "empty or unknown plan")
    rows = plan.get("files")
    require(isinstance(rows, list) and rows, "empty or unknown plan")
    names = []
    for row in rows:
        require(isinstance(row, dict) and set(row) == {"path", "before", "after"}, "invalid plan row")
        require(isinstance(row["path"], str), "invalid path")
        names.append(row["path"])
        before = row["before"]
        require(isinstance(before, dict), "invalid before metadata")
        kind = before.get("kind")
        fields = {"absent": {"kind"}, "file": {"kind", "mode", "uid", "gid", "sha256"},
                  "symlink": {"kind", "mode", "uid", "gid", "target"}}
        require(kind in fields and set(before) == fields[kind], "incomplete or unexpected before metadata")
        if kind != "absent":
            for name in ("mode", "uid", "gid"):
                require(type(before[name]) is int and before[name] >= 0, "invalid before metadata")
            require(before["mode"] <= 0o7777, "invalid before mode")
            require(before["uid"] < 2**32 - 1 and before["gid"] < 2**32 - 1, "invalid before ownership")
        if kind == "file":
            require(isinstance(before["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", before["sha256"]), "invalid before digest")
        elif kind == "symlink":
            require(isinstance(before["target"], str) and bool(before["target"]), "invalid before symlink")
        after = row["after"]
        require(isinstance(after, dict), "invalid after metadata")
        if after.get("kind") == "absent":
            require(set(after) == {"kind"}, "unexpected absent metadata")
        else:
            require(after.get("kind") == "file" and set(after) == {"kind", "mode", "uid", "gid", "sha256", "data"}, "invalid after file metadata")
            require(type(after["mode"]) is int and after["mode"] in (0o600, 0o644, 0o755), "unexpected file mode")
            for name in ("uid", "gid"):
                require(type(after[name]) is int and 0 <= after[name] < 2**32 - 1, "invalid after ownership")
            require(isinstance(after["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", after["sha256"]), "invalid after digest")
            require(isinstance(after["data"], str) and len(after["data"]) <= 1398104, "invalid after payload")
            try:
                data = base64.b64decode(after["data"], validate=True)
            except (ValueError, TypeError) as error:
                raise RuntimeError("invalid after payload") from error
            require(len(data) <= 1024 * 1024 and base64.b64encode(data).decode() == after["data"], "invalid after payload")
            require(hashlib.sha256(data).hexdigest() == after["sha256"], "payload digest mismatch")
    require(len(set(names)) == len(names), "duplicate destinations")


def matches(actual, expected):
    return all(
        actual.get(key) == value for key, value in expected.items() if key != "data"
    )


def sync_parent(path):
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".journal-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_parent(path)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def put(path, row):
    if row["kind"] == "absent":
        if os.path.lexists(path):
            path.unlink()
            sync_parent(path)
        return
    if row["kind"] == "symlink":
        fd, name = tempfile.mkstemp(prefix=".touchid-", dir=path.parent)
        os.close(fd)
        os.unlink(name)
        os.symlink(row["target"], name)
    else:
        data = base64.b64decode(row["data"], validate=True)
        require(
            hashlib.sha256(data).hexdigest() == row["sha256"], "payload digest mismatch"
        )
        fd, name = tempfile.mkstemp(prefix=".touchid-", dir=path.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            if os.geteuid() == 0:
                os.fchown(stream.fileno(), row["uid"], row["gid"])
            os.fchmod(stream.fileno(), row["mode"])
            os.fsync(stream.fileno())
    try:
        if row["kind"] == "symlink" and os.geteuid() == 0:
            os.lchown(name, row["uid"], row["gid"])
        os.replace(name, path)
        sync_parent(path)
    finally:
        if os.path.lexists(name):
            os.unlink(name)


def rollback(root, checkpoint):
    journal = json.loads((checkpoint / "journal.json").read_text())
    # Validate the entire inverse before restoring any file.
    for row in journal["files"]:
        actual = snapshot(path_at(root, row["path"]))
        require(
            matches(actual, row["before"]) or matches(actual, row["after"]),
            "configuration changed since transition: " + row["path"],
        )
    for row in reversed(journal["files"]):
        path = path_at(root, row["path"])
        actual = snapshot(path)
        if matches(actual, row["before"]):
            continue  # Never rewrite an untouched row; it may be unwritable.
        require(matches(actual, row["after"]), "configuration changed during rollback: " + row["path"])
        put(path, row["before"])
    for name in reversed(journal["created_directories"]):
        path = root / name.lstrip("/")
        try:
            path.rmdir()
        except OSError:
            pass  # An administrator's new file must remain untouched.
    journal["status"] = "ROLLED_BACK"
    atomic_json(checkpoint / "journal.json", journal)


def apply(root, plan, checkpoint, fail_after=None):
    validate_plan(plan)
    rows = []
    for row in plan["files"]:
        actual = snapshot(path_at(root, row["path"]))
        require(matches(actual, row["before"]), "preflight changed: " + row["path"])
        after = row["after"]
        require(after["kind"] in ("file", "absent"), "new symlinks are not supported")
        if after["kind"] == "file":
            data = base64.b64decode(after["data"], validate=True)
            require(
                hashlib.sha256(data).hexdigest() == after["sha256"],
                "payload digest mismatch",
            )
            require(after["mode"] in (0o600, 0o644, 0o755), "unexpected file mode")
        rows.append(dict(path=row["path"], before=actual, after=after))
    checkpoint.mkdir(mode=0o700, parents=False, exist_ok=False)
    journal = dict(schema=1, status="PREPARED", files=rows, created_directories=[])
    atomic_json(checkpoint / "journal.json", journal)
    # Publish the checkpoint path, including ancestors created by the CLI,
    # before any configuration replacement can become durable.
    ancestor = checkpoint.absolute()
    while ancestor != ancestor.parent:
        sync_parent(ancestor)
        ancestor = ancestor.parent
    try:
        for index, row in enumerate(rows):
            path = path_at(root, row["path"])
            require(
                matches(snapshot(path), row["before"]),
                "concurrent configuration change",
            )
            missing = []
            parent = path.parent
            while not parent.exists():
                missing.append(parent)
                parent = parent.parent
            for parent in reversed(missing):
                journal["created_directories"].append(
                    "/" + str(parent.relative_to(root))
                )
                atomic_json(checkpoint / "journal.json", journal)
                parent.mkdir(mode=0o755)
                # The new name lives in the parent; flush that entry before
                # anything inside the directory can be recorded as applied.
                sync_parent(parent)
            put(path, row["after"])
            journal["last_written"] = index
            atomic_json(checkpoint / "journal.json", journal)
            if fail_after == index:
                raise RuntimeError("injected interrupted transaction")
        journal["status"] = "APPLIED"
        atomic_json(checkpoint / "journal.json", journal)
    except BaseException:
        rollback(root, checkpoint)
        raise


def ready_for_transition(plan, result):
    if plan.get("phase") != "preserve-existing-consent":
        return result.get("action") == "ready-for-test"
    # An existing experimental installation predates package-owned consent.
    names = {row["path"] for row in plan["files"]}
    facts = result.get("facts", {})
    return (
        names
        == {"/etc/omarchy-mac/touchid-on", "/etc/modprobe.d/omarchy-mac-touchid.conf"}
        and all(row["before"] == {"kind": "absent"} for row in plan["files"])
        and result.get("action") in {"ready-for-test", "unsupported", "setup"}
        and result.get("node_present") is True
        and all(
            facts.get(k) == v
            for k, v in {
                "keystore": "open",
                "keybag": "present",
                "host_store": "ready",
                "xart": "enabled",
                "sensor": "online",
                "touchid": "ready",
                "sensor_attach": "attached",
                "restore": "restored",
                "matching": "usable",
                "refusals": 0,
            }.items()
        )
    )


def recovery_report(command):
    path = Path(command)
    require(
        path.is_file() and os.access(path, os.X_OK),
        "omarchy-mac readiness report is not installed: " + str(path),
    )
    try:
        result = subprocess.run(
            [os.fspath(path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        raise RuntimeError(
            "omarchy-mac readiness report could not be run: " + str(path)
        ) from error
    require(
        result.returncode == 0,
        "omarchy-mac readiness report failed: " + str(path),
    )
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("omarchy-mac readiness report is not JSON") from error
    require(isinstance(report, dict), "omarchy-mac readiness report is not JSON")
    return report


def require_recovery(plan, command):
    require(
        ready_for_transition(plan, recovery_report(command)),
        "replacement driver is not ready for the attended trial",
    )


def acquire_transition_lock(root):
    # One file per target root, so a second checkpoint cannot pass it.
    path = root / "run/omarchy-mac/touchid-transition.lock"
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except BaseException:
        os.close(fd)
        raise
    return fd


def safe_checkpoint_parent(path):
    require(
        path.is_absolute() and str(path) == str(path.resolve()),
        "unsafe checkpoint path",
    )
    for parent in [*reversed(path.parents), path]:
        info = parent.lstat()
        require(
            stat.S_ISDIR(info.st_mode)
            and info.st_uid == 0
            and not info.st_mode & 0o022,
            "unsafe checkpoint parent",
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check", "apply", "rollback"))
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path("/"))
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--accepted-hardware", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    plan = json.loads(args.plan.read_text())
    if args.operation != "rollback":
        validate_plan(plan)
    if root == Path("/"):
        require(
            args.live and os.geteuid() == 0 and os.isatty(0),
            "live transition requires an attended root terminal and --live",
        )
        # These are migration prerequisites, never proof of a finger match.
        if args.operation != "rollback":
            require(
                "/sys/module/apple_sep/notes/.note.gnu.build-id"
                in plan["required_files"],
                "missing running-module pin",
            )
            require(
                not plan.get("hardware_acceptance_required") or args.accepted_hardware,
                "retirement requires explicit completed hardware acceptance",
            )
            require(
                os.uname().release == plan["kernel_release"], "different running kernel"
            )
            for name, expected in plan["required_files"].items():
                require(
                    hashlib.sha256(Path(name).read_bytes()).hexdigest() == expected,
                    "required replacement differs: " + name,
                )
            if args.operation == "apply":
                require_recovery(plan, RECOVERY_REPORT)
    if args.operation == "check":
        for row in plan["files"]:
            require(
                matches(snapshot(path_at(root, row["path"])), row["before"]),
                "preflight changed: " + row["path"],
            )
        print("Configuration and replacement prerequisites match; nothing activated.")
        return
    fd = acquire_transition_lock(root)
    with os.fdopen(fd, "w"):
        args.checkpoint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if root == Path("/"):
            safe_checkpoint_parent(args.checkpoint.parent)
        if args.operation == "rollback":
            rollback(root, args.checkpoint)
        elif args.operation == "apply":
            apply(root, plan, args.checkpoint)


if __name__ == "__main__":
    main()
