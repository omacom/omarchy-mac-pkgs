#!/usr/bin/python3
import base64
import hashlib
import json
import os
import shlex
import stat
import subprocess
import sys
from unittest import mock
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "transition", Path(__file__).parents[1] / "touchid-transition.py"
)
T = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(T)


def content(data, uid, gid):
    return dict(
        kind="file",
        data=base64.b64encode(data).decode(),
        sha256=hashlib.sha256(data).hexdigest(),
        mode=0o644,
        uid=uid,
        gid=gid,
    )


class TransitionTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "etc/pam.d").mkdir(parents=True)
        (root / "checkpoints").mkdir()
        path = root / "etc/pam.d/test"
        path.write_bytes(b"old\n")
        path.chmod(0o644)
        before = T.snapshot(path)
        plan = dict(
            schema=1,
            files=[
                dict(
                    path="/etc/pam.d/test",
                    before={k: v for k, v in before.items() if k != "data"},
                    after=content(b"new\n", before["uid"], before["gid"]),
                ),
                dict(
                    path="/etc/omarchy-mac/touchid-on",
                    before=dict(kind="absent"),
                    after=content(b"consent\n", before["uid"], before["gid"]),
                ),
            ],
        )
        return root, plan, root / "checkpoints/run"

    def test_existing_consent_needs_exact_healthy_restored_state(self):
        plan = {
            "phase": "preserve-existing-consent",
            "files": [
                {"path": p, "before": {"kind": "absent"}}
                for p in (
                    "/etc/omarchy-mac/touchid-on",
                    "/etc/modprobe.d/omarchy-mac-touchid.conf",
                )
            ],
        }
        facts = dict(
            keystore="open",
            keybag="present",
            host_store="ready",
            xart="enabled",
            sensor="online",
            touchid="ready",
            sensor_attach="attached",
            restore="restored",
            matching="usable",
            refusals=0,
        )
        report = dict(action="unsupported", facts=facts, node_present=True)
        self.assertTrue(T.ready_for_transition(plan, report))
        for key in facts:
            changed = dict(facts)
            changed.pop(key)
            self.assertFalse(
                T.ready_for_transition(plan, dict(action="unsupported", facts=changed, node_present=True))
            )
        for action in (
            "preserve-state",
            "ownership-review",
            "storage-policy-review",
            "wait",
        ):
            self.assertFalse(
                T.ready_for_transition(plan, dict(action=action, facts=facts, node_present=True))
            )
        for node in (False, None):
            self.assertFalse(T.ready_for_transition(plan, dict(action="unsupported", facts=facts, node_present=node)))
        plan["files"][0]["path"] = "/etc/pam.d/sddm"
        self.assertFalse(T.ready_for_transition(plan, report))
        self.assertFalse(T.ready_for_transition({}, report))

    def test_incomplete_or_extra_before_metadata_refused_before_apply(self):
        for missing in ("sha256", "mode", "uid", "gid"):
            root, plan, cp = self.fixture()
            del plan["files"][0]["before"][missing]
            with self.assertRaisesRegex(RuntimeError, "metadata"):
                T.validate_plan(plan)
            with self.assertRaisesRegex(RuntimeError, "metadata"):
                T.apply(root, plan, cp)
            self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
            self.assertFalse(cp.exists())
        root, plan, cp = self.fixture()
        plan["files"][0]["before"]["unexpected"] = True
        with self.assertRaisesRegex(RuntimeError, "metadata"):
            T.apply(root, plan, cp)
        self.assertFalse(cp.exists())

    def test_invalid_after_rejected_by_check_and_apply_before_any_write(self):
        variants = [lambda a: a.update(extra=True), lambda a: a.update(data="bad!"),
                    lambda a: a.update(mode=True), lambda a: a.update(uid=-1),
                    lambda a: a.update(sha256="0" * 64),
                    lambda a: a.update(content(b"x" * (1024 * 1024 + 1), a["uid"], a["gid"]))]
        for change in variants:
            root, plan, cp = self.fixture()
            change(plan["files"][0]["after"])
            plan_path = root / "plan.json"
            plan_path.write_text(json.dumps(plan))
            for operation in ("check", "apply"):
                result = subprocess.run([sys.executable, str(Path(T.__file__)), operation, "--root", str(root),
                                         "--plan", str(plan_path), "--checkpoint", str(cp)], capture_output=True)
                self.assertNotEqual(result.returncode, 0, operation)
                self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
                self.assertFalse(cp.exists())
        root, plan, cp = self.fixture()
        plan["files"][0]["after"] = dict(kind="absent", extra=True)
        with self.assertRaises(RuntimeError): T.apply(root, plan, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")

    def test_rollback_restores_special_mode_after_chown(self):
        root, plan, cp = self.fixture()
        path = root / "etc/pam.d/test"
        path.chmod(0o6755)
        before = T.snapshot(path)
        plan["files"][0]["before"] = {k: v for k, v in before.items() if k != "data"}
        with self.assertRaisesRegex(RuntimeError, "injected"):
            T.apply(root, plan, cp, fail_after=0)
        self.assertEqual(T.snapshot(path), before)
        # Emulate root to verify that ownership is set before the final mode.
        calls = []
        actual_chmod = os.fchmod
        with mock.patch.object(T.os, "geteuid", return_value=0), \
             mock.patch.object(T.os, "fchown", side_effect=lambda *args: calls.append("chown")), \
             mock.patch.object(T.os, "fchmod", side_effect=lambda fd, mode: (calls.append("chmod"), actual_chmod(fd, mode))):
            T.put(path, before)
        self.assertEqual(calls, ["chown", "chmod"])
        self.assertEqual(T.snapshot(path), before)

    def test_snapshot_rejects_changed_metadata_on_open(self):
        root, _, _ = self.fixture()
        path = root / "etc/pam.d/test"
        actual = os.fstat
        def changed(fd):
            value = list(actual(fd))
            value[0] ^= 0o100
            return os.stat_result(value)
        with mock.patch.object(T.os, "fstat", side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, "metadata"):
                T.snapshot(path)

    def test_apply_and_exact_inverse(self):
        root, plan, cp = self.fixture()
        T.apply(root, plan, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"new\n")
        T.rollback(root, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        self.assertFalse((root / "etc/omarchy-mac").exists())

    def test_checkpoint_ancestors_are_durable_before_any_replacement(self):
        root, plan, _ = self.fixture()
        cp = root / "checkpoints/new/nested/run"
        cp.parent.mkdir(parents=True)
        parents = [cp.parent, cp.parent.parent, root / "checkpoints", root]
        required = {(p.stat().st_dev, p.stat().st_ino) for p in parents}
        synced = set()
        real_sync, real_put = T.os.fsync, T.put

        def sync(fd):
            info = os.fstat(fd)
            result = real_sync(fd)
            synced.add((info.st_dev, info.st_ino))
            return result

        def replace(path, row):
            self.assertTrue(required <= synced, "checkpoint path is not durable")
            return real_put(path, row)

        with mock.patch.object(T.os, "fsync", side_effect=sync), \
             mock.patch.object(T, "put", side_effect=replace):
            T.apply(root, plan, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"new\n")
        T.rollback(root, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")

    def test_checkpoint_parent_sync_failure_prevents_all_replacements(self):
        for level in range(4):
            root, plan, _ = self.fixture()
            cp = root / "checkpoints/new/nested/run"
            cp.parent.mkdir(parents=True)
            parent = [cp.parent, cp.parent.parent, root / "checkpoints", root][level]
            info = parent.stat()
            failing_inode = (info.st_dev, info.st_ino)
            real_sync = T.os.fsync

            def fail(fd):
                info = os.fstat(fd)
                if (info.st_dev, info.st_ino) == failing_inode:
                    raise OSError("injected checkpoint publication failure")
                return real_sync(fd)

            with mock.patch.object(T.os, "fsync", side_effect=fail), \
                 mock.patch.object(T, "put", wraps=T.put) as replace:
                with self.assertRaisesRegex(OSError, "checkpoint publication"):
                    T.apply(root, plan, cp)
                replace.assert_not_called()
            self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
            self.assertFalse((root / "etc/omarchy-mac/touchid-on").exists())

    def test_fault_after_each_replacement_rolls_back(self):
        for at in (0, 1):
            root, plan, cp = self.fixture()
            with self.assertRaisesRegex(RuntimeError, "injected"):
                T.apply(root, plan, cp, fail_after=at)
            self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
            self.assertFalse((root / "etc/omarchy-mac/touchid-on").exists())

    def test_unwritable_untouched_later_row_does_not_prevent_rollback(self):
        root, plan, cp = self.fixture()
        later = root / "etc/omarchy-mac/touchid-on"
        later.parent.mkdir()
        later.write_text("unchanged")
        before = T.snapshot(later)
        plan["files"][1]["before"] = {k: v for k, v in before.items() if k != "data"}
        original_put = T.put
        calls = []
        def fail_later(path, row):
            calls.append(path)
            if path == later: raise PermissionError("injected unwritable destination")
            return original_put(path, row)
        with mock.patch.object(T, "put", side_effect=fail_later):
            with self.assertRaises(PermissionError): T.apply(root, plan, cp)
        self.assertEqual(T.snapshot(later), before)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        self.assertEqual(calls.count(later), 1)

    def test_changed_late_destination_changes_nothing(self):
        root, plan, cp = self.fixture()
        (root / "etc/omarchy-mac").mkdir()
        (root / "etc/omarchy-mac/touchid-on").write_text("admin")
        with self.assertRaisesRegex(RuntimeError, "preflight"):
            T.apply(root, plan, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        self.assertFalse(cp.exists())

    def test_rollback_preserves_administrator_edits(self):
        root, plan, cp = self.fixture()
        T.apply(root, plan, cp)
        (root / "etc/pam.d/test").write_text("admin")
        with self.assertRaisesRegex(RuntimeError, "changed"):
            T.rollback(root, cp)
        self.assertEqual((root / "etc/pam.d/test").read_text(), "admin")
        self.assertTrue((root / "etc/omarchy-mac/touchid-on").exists())

    def test_symlink_parent_is_refused(self):
        root, plan, cp = self.fixture()
        (root / "etc/omarchy-mac").symlink_to(
            root / "etc/pam.d", target_is_directory=True
        )
        with self.assertRaisesRegex(RuntimeError, "parent"):
            T.apply(root, plan, cp)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")

    def test_duplicate_path_or_bad_payload_is_refused(self):
        for duplicate in (False, True):
            root, plan, cp = self.fixture()
            if duplicate:
                plan["files"].append(plan["files"][0])
            else:
                plan["files"][1]["after"]["sha256"] = "0" * 64
            with self.assertRaises(RuntimeError):
                T.apply(root, plan, cp)
            self.assertFalse(cp.exists())

    def test_enrollment_and_traversal_are_never_targets(self):
        for name in (
            "/var/lib/fprint/data",
            "/var/lib/aurora-sep-keybag.bin",
            "/etc/pam.d/../../var/lib/fprint/data",
        ):
            root, plan, cp = self.fixture()
            plan["files"][1]["path"] = name
            with self.assertRaises(RuntimeError):
                T.apply(root, plan, cp)
            self.assertFalse(cp.exists())

    def test_removed_symlink_is_restored_as_link(self):
        root, plan, cp = self.fixture()
        p = root / "etc/pam.d/test"
        p.unlink()
        p.symlink_to("original")
        plan["files"] = [
            dict(
                path="/etc/pam.d/test", before=T.snapshot(p), after=dict(kind="absent")
            )
        ]
        T.apply(root, plan, cp)
        self.assertFalse(p.is_symlink())
        T.rollback(root, cp)
        self.assertEqual(p.readlink(), Path("original"))

    def test_created_directory_parent_is_synced_before_applied(self):
        root, plan, cp = self.fixture()
        created = root / "etc/omarchy-mac"
        etc = root / "etc"
        etc_id = (etc.stat().st_dev, etc.stat().st_ino)
        events = []
        real_mkdir, real_sync, real_atomic = os.mkdir, T.os.fsync, T.atomic_json

        def mkdir(path, mode=0o777):
            events.append(("mkdir", os.path.abspath(path)))
            return real_mkdir(path, mode)

        def sync(fd):
            info = os.fstat(fd)
            events.append(("fsync", (info.st_dev, info.st_ino)))
            return real_sync(fd)

        def atomic(path, value):
            if isinstance(value, dict) and value.get("status") == "APPLIED":
                events.append(("applied",))
            return real_atomic(path, value)

        with mock.patch.object(os, "mkdir", side_effect=mkdir), \
             mock.patch.object(T.os, "fsync", side_effect=sync), \
             mock.patch.object(T, "atomic_json", side_effect=atomic):
            T.apply(root, plan, cp)
        created_id = (created.stat().st_dev, created.stat().st_ino)
        mkdir_at = events.index(("mkdir", os.path.abspath(created)))
        parent_sync = next(
            index for index, event in enumerate(events)
            if index > mkdir_at and event == ("fsync", etc_id)
        )
        created_sync = next(
            index for index, event in enumerate(events)
            if index > mkdir_at and event == ("fsync", created_id)
        )
        applied_at = events.index(("applied",))
        self.assertLess(mkdir_at, parent_sync)
        self.assertLess(parent_sync, created_sync)
        self.assertLess(parent_sync, applied_at)
        self.assertEqual((root / "etc/omarchy-mac/touchid-on").read_bytes(), b"consent\n")
        T.rollback(root, cp)
        self.assertFalse(created.exists())

    def test_created_directory_parent_sync_failure_rolls_back(self):
        root, plan, cp = self.fixture()
        etc = root / "etc"
        etc_id = (etc.stat().st_dev, etc.stat().st_ino)
        failed = False
        real_sync = T.os.fsync

        def sync(fd):
            nonlocal failed
            info = os.fstat(fd)
            if not failed and stat.S_ISDIR(info.st_mode) and (info.st_dev, info.st_ino) == etc_id:
                failed = True
                raise OSError("injected directory publication failure")
            return real_sync(fd)

        with mock.patch.object(T.os, "fsync", side_effect=sync):
            with self.assertRaisesRegex(OSError, "directory publication"):
                T.apply(root, plan, cp)
        self.assertTrue(failed)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        self.assertFalse((root / "etc/omarchy-mac").exists())

    def helper(self, root, body):
        path = root / "touchid-recovery"
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def test_recovery_command_is_run_and_a_missing_helper_stops(self):
        root, plan, _ = self.fixture()
        missing = root / "no-such-report"
        try:
            T.require_recovery(plan, missing)
        except FileNotFoundError:
            self.fail("a missing readiness report raised FileNotFoundError")
        except RuntimeError as error:
            self.assertIn("not installed", str(error))
            self.assertIn(str(missing), str(error))
        else:
            self.fail("a missing readiness report was accepted")
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        marker = root / "helper-ran"
        helper = self.helper(
            root,
            "printf ran > " + shlex.quote(str(marker)) + "\nprintf '%s\\n' '{\"action\":\"ready-for-test\"}'\n",
        )
        self.assertIsNone(T.require_recovery(plan, helper))
        self.assertEqual(marker.read_text(), "ran")
        self.helper(root, "printf '%s\\n' 'not-json'\n")
        with self.assertRaisesRegex(RuntimeError, "not JSON"):
            T.require_recovery(plan, helper)
        self.helper(root, "exit 3\n")
        with self.assertRaisesRegex(RuntimeError, "failed"):
            T.require_recovery(plan, helper)
        self.helper(root, "printf '%s\\n' '{\"action\":\"setup\"}'\n")
        with self.assertRaisesRegex(RuntimeError, "not ready"):
            T.require_recovery(plan, helper)
        with mock.patch.object(T.subprocess, "run", side_effect=FileNotFoundError("gone")):
            with self.assertRaisesRegex(RuntimeError, "could not be run") as caught:
                T.recovery_report(helper)
        self.assertIsInstance(caught.exception.__cause__, FileNotFoundError)
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")

    def test_distinct_checkpoint_parents_use_the_target_root_lock(self):
        root, plan, cp = self.fixture()
        plan_path = root / "plan.json"
        plan_path.write_text(json.dumps(plan))
        lock = root / "run/omarchy-mac/touchid-transition.lock"
        lock.parent.mkdir(parents=True)
        lock.mkdir()
        script = str(Path(T.__file__))
        for checkpoint in (cp, root / "elsewhere/run"):
            result = subprocess.run(
                [sys.executable, script, "apply", "--root", str(root), "--plan", str(plan_path),
                 "--checkpoint", str(checkpoint)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
            self.assertFalse((root / "etc/omarchy-mac/touchid-on").exists())
            self.assertFalse(checkpoint.exists())
        lock.rmdir()
        result = subprocess.run(
            [sys.executable, script, "apply", "--root", str(root), "--plan", str(plan_path),
             "--checkpoint", str(cp)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(lock.is_file())
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"new\n")

    def test_another_target_root_is_not_blocked_by_this_lock(self):
        root, plan, _ = self.fixture()
        fd = T.acquire_transition_lock(root)
        self.addCleanup(os.close, fd)
        probe = subprocess.run(
            [sys.executable, "-c", LOCK_PROBE, str(root / "run/omarchy-mac/touchid-transition.lock")],
            capture_output=True, text=True,
        )
        self.assertEqual(probe.stdout.strip(), "busy", probe.stderr)
        other, other_plan, other_cp = self.fixture()
        other_plan_path = other / "plan.json"
        other_plan_path.write_text(json.dumps(other_plan))
        result = subprocess.run(
            [sys.executable, str(Path(T.__file__)), "apply", "--root", str(other),
             "--plan", str(other_plan_path), "--checkpoint", str(other_cp)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((other / "etc/pam.d/test").read_bytes(), b"new\n")
        self.assertEqual((root / "etc/pam.d/test").read_bytes(), b"old\n")
        free = subprocess.run(
            [sys.executable, "-c", LOCK_PROBE, str(other / "run/omarchy-mac/touchid-transition.lock")],
            capture_output=True, text=True,
        )
        self.assertEqual(free.stdout.strip(), "free", free.stderr)


LOCK_PROBE = """
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("busy")
else:
    print("free")
"""


if __name__ == "__main__":
    unittest.main(verbosity=2)
