"""Guard behavior using disposable copies: cancellation/restoration and host-versus-sync exclusion."""
from __future__ import annotations

import fcntl
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hub.candidate import ROOT
from hub.processes import finish_owned_group, group_members


class ValidationLockTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix="guard-test-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, self.folder)
        (self.folder / "Tools").mkdir()
        self.guard = self.folder / "Tools" / "validation-lock.py"
        shutil.copyfile(ROOT / "Tools" / "validation-lock.py", self.guard)
        # Guard copies are intentionally self-contained: no Hub package is copied into this root.
        self.resolved = self.folder / "Package.resolved"
        self.original = b"original package bytes\n"
        self.resolved.write_bytes(self.original)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("NTP_VALIDATION_LOCK_")}

    def start(self, script, kind="host", restore=True):
        arguments = [sys.executable, str(self.guard), "--kind", kind]
        if restore:
            arguments.append("--restore-package-resolved")
        arguments.extend(["--", sys.executable, "-c", script])
        process = subprocess.Popen(arguments, cwd=self.folder, env=self.environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.finish, process)
        return process

    def finish(self, process):
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=45)

    def ready(self, process):
        with selectors.DefaultSelector() as readiness:
            readiness.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(readiness.select(5), "controlled command did not reach its readiness condition")
        self.assertEqual(process.stdout.readline(), b"ready\n")

    def test_failed_host_restores_exact_original_or_absent_lockfile(self):
        for existed in (True, False):
            if not existed:
                self.resolved.unlink()
            process = self.start("from pathlib import Path; Path('Package.resolved').write_bytes(b'changed'); raise SystemExit(7)")
            _, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 7, error)
            self.assertEqual(self.resolved.read_bytes() if self.resolved.exists() else None,
                             self.original if existed else None)

    def test_cancelled_host_confirms_child_exit_then_restores_lockfile(self):
        process = self.start("from pathlib import Path; import signal; Path('Package.resolved').write_bytes(b'changed'); "
                             "print('ready',flush=True); signal.pause()")
        self.ready(process)
        self.assertEqual(self.resolved.read_bytes(), b"changed")
        process.terminate()
        _, error = process.communicate(timeout=45)
        self.assertEqual(process.returncode, 143, error)
        self.assertEqual(self.resolved.read_bytes(), self.original)

    def test_unconfirmed_child_finalization_preserves_original_without_early_restoration(self):
        script = ("import importlib.util,sys; "
                  f"spec=importlib.util.spec_from_file_location('guard',{str(self.guard)!r}); "
                  "guard=importlib.util.module_from_spec(spec); spec.loader.exec_module(guard); "
                  "guard.finish_command=lambda process, **options: (_ for _ in ()).throw(RuntimeError('controlled finalization failure')); "
                  "sys.argv=['guard','--kind','host','--restore-package-resolved','--',sys.executable,'-c',"
                  "\"from pathlib import Path; Path('Package.resolved').write_bytes(b'changed')\"]; guard.main()")
        result = subprocess.run([sys.executable, "-c", script], cwd=self.folder, env=self.environment,
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("controlled finalization failure", result.stderr)
        self.assertEqual(self.resolved.read_bytes(), b"changed", "no restore while child exit remains unconfirmed")
        pending = list((self.folder / ".work" / "validation").glob("restore-pending-*"))
        self.assertEqual(len(pending), 1)
        self.assertEqual((pending[0] / "Package.resolved").read_bytes(), self.original)
        self.assertEqual((pending[0] / "Package.resolved").stat().st_mode & 0o777, 0o600)

    def test_failed_hub_receipt_restores_exact_package_after_managed_children_exit(self):
        self.resolved.chmod(0o640)
        package = self.folder / "TestSupport" / "Servers" / "hub"
        package.mkdir(parents=True)
        helper = package / "processes.py"
        shutil.copyfile(ROOT / "TestSupport" / "Servers" / "hub" / "processes.py", helper)
        script = ("import importlib.util,json,os,signal,sys; from pathlib import Path; "
                  f"spec=importlib.util.spec_from_file_location('owned',{str(helper)!r}); "
                  "owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned); "
                  "child=owned.owned_popen([sys.executable,'-c','import signal; signal.pause()']); "
                  "Path('managed-child.pid').write_text(str(child.pid)); "
                  "Path('Package.resolved').write_bytes(b'changed'); "
                  "(Path(os.environ['NTP_HUB_TERMINAL_REGISTRY'])/'failed.json').write_text("
                  "json.dumps({'quiesced':False,'retention_failed':True,'primary_error':'controlled Hub failure'})); "
                  "print('ready',flush=True); signal.pause()")
        process = self.start(script)
        self.ready(process)
        child = int((self.folder / "managed-child.pid").read_text())
        self.assertIn(child, group_members(child))
        process.terminate()
        _, error = process.communicate(timeout=45)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn(b"Hub terminal shutdown/retention is incomplete", error)
        self.assertEqual(group_members(child), [])
        self.assertEqual(self.resolved.read_bytes(), self.original, "all writer/managed groups exited, so retention failure still restores")
        self.assertEqual(self.resolved.stat().st_mode & 0o777, 0o640)
        managed = next((self.folder / ".work" / "validation" / "managed").iterdir())
        terminal = json.loads((managed / "terminal.json").read_text())
        self.assertTrue(terminal["groups_exited"])
        self.assertFalse(terminal["quiesced"])
        self.assertTrue((managed / "unfinished.json").exists())
        self.assertFalse(list((self.folder / ".work" / "validation").glob("restore-pending-*")))
        # Evidence failure keeps a separate lease, rather than leaving Package.resolved changed.
        sync = self.start("raise SystemExit('must not run')", kind="sync", restore=False)
        _, error = sync.communicate(timeout=15)
        self.assertEqual(sync.returncode, 1)
        self.assertIn(b"managed shutdown ownership unresolved", error)

    def test_actual_host_cancellation_and_finish_command_capture_browser_survivors(self):
        package = self.folder / "TestSupport" / "Servers" / "hub"
        package.mkdir(parents=True)
        shutil.copyfile(ROOT / "TestSupport" / "Servers" / "hub" / "processes.py", package / "processes.py")
        synthetic = Path(__file__).with_name("synthetic_browser_creator.py")
        for cancellation in (True, False):
            with self.subTest(cancellation=cancellation):
                records = self.folder / ("cancel-browser" if cancellation else "finish-browser")
                def recovery(records=records):
                    if (records / "recovery.json").exists():
                        finish_owned_group(json.loads((records / "recovery.json").read_text()), timeout=0)
                self.addCleanup(recovery)
                argv = [sys.executable, str(synthetic), "--mode", "signal", "--records", str(records), "--write-package"]
                if cancellation:
                    script = f"import os; os.execv({sys.executable!r}, {argv!r})"
                else:
                    # The command leader exits after creator readiness; finish_command must cancel its
                    # remaining same-group creator, whose browser is in a separately registered group.
                    script = ("import subprocess\n"
                              f"creator=subprocess.Popen({argv!r},stdout=subprocess.PIPE)\n"
                              "assert creator.stdout.readline()==b'ready\\n'\n"
                              "creator.stdout.close()\n"
                              "print('ready',flush=True)\n")
                process = self.start(script)
                self.ready(process)
                ready = json.loads((records / "ready.json").read_text())
                initial = json.loads((records / "initial.json").read_text())
                self.assertNotIn(str(ready["renderer"]), initial["members"])
                if cancellation:
                    process.terminate()
                _, error = process.communicate(timeout=45)
                self.assertEqual(process.returncode, 143 if cancellation else 0, error)
                cancelled = json.loads((records / "cancel.json").read_text())
                self.assertTrue(cancelled["renderer_authenticated_before_cancel"])
                self.assertTrue(cancelled["browser_leader_exited"])
                self.assertTrue(cancelled["renderer_survived_creator_cleanup"])
                self.assertEqual(group_members(ready["browser"]), [])
                self.assertEqual(group_members(ready["creator_group"]), [])
                receipt = json.loads(Path(ready["receipt"]).read_text())
                self.assertTrue(receipt["exited"])
                self.assertIn(str(ready["renderer"]), receipt["members"])
                terminal = json.loads((Path(ready["receipt"]).parents[1] / "terminal.json").read_text())
                self.assertTrue(terminal["groups_exited"])
                self.assertTrue(terminal["quiesced"])
                self.assertIn(b"synthetic creator final tail", error)
                self.assertEqual(self.resolved.read_bytes(), self.original)
                self.assertFalse(list((self.folder / ".work" / "validation").glob("restore-pending-*")))

    def test_contract_sync_waits_until_the_host_finishes(self):
        host = self.start("from pathlib import Path; import sys; Path('host-active').touch(); print('ready',flush=True); "
                          "sys.stdin.readline(); Path('host-active').unlink(); Path('host-finished').touch()")
        self.ready(host)
        lock = self.folder / ".work" / "validation" / "host-fixture.lock"
        with lock.open("r+") as descriptor:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sync = self.start("from pathlib import Path; assert not Path('host-active').exists(); "
                          "assert Path('host-finished').exists(); Path('sync-finished').touch()", kind="sync", restore=False)
        host.stdin.write(b"finish\n")
        host.stdin.flush()
        _, host_error = host.communicate(timeout=15)
        _, sync_error = sync.communicate(timeout=15)
        self.assertEqual(host.returncode, 0, host_error)
        self.assertEqual(sync.returncode, 0, sync_error)
        self.assertTrue((self.folder / "sync-finished").exists())

    def test_idle_unleased_pid_is_recorded_without_becoming_a_host_blocker(self):
        state = self.folder / ".work" / "test-fixtures"
        state.mkdir(parents=True)
        (state / "idle.pid").write_text(str(os.getpid()))
        process = self.start("pass")
        _, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, error)
        receipt = (self.folder / ".work" / "validation" / "lease-observation.json").read_text()
        self.assertIn("idle.pid", receipt)
        self.assertTrue((state / "idle.pid").exists())

    def test_an_active_fixture_test_lease_blocks_quiet_host_without_signalling_it(self):
        state = self.folder / ".work" / "test-fixtures"
        (state / "users.d").mkdir(parents=True)
        (state / "owned.pid").write_text(str(os.getpid()))
        (state / "users.d" / "controlled-run").touch()
        process = self.start("raise SystemExit('must not run')")
        _, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 1)
        self.assertIn(b"stop the test-owned fixtures", error)
        self.assertTrue((state / "owned.pid").exists())

    def test_verified_nested_descriptor_does_not_deadlock(self):
        script = ("import os,subprocess,sys; "
                  "descriptor=int(os.environ['NTP_VALIDATION_LOCK_FD']); "
                  f"raise SystemExit(subprocess.call([sys.executable,{str(self.guard)!r},'--kind','sync','--',"
                  "sys.executable,'-c','pass'],pass_fds=(descriptor,)))")
        process = self.start(script)
        _, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, error)

    def test_unreleased_registration_blocks_host_and_sync_without_live_fixtures(self):
        state = self.folder / ".work" / "test-fixtures"
        registry = state / "users.d"
        registry.mkdir(parents=True)
        registration = registry / "controlled-run"
        # A real synthetic child has exited; no foreign PID is probed or signalled by this test.
        exited = subprocess.Popen([sys.executable, "-c", "pass"])
        exited.wait(timeout=5)
        for with_pid in (False, True):
            if with_pid:
                (state / "owned.pid").write_text(str(exited.pid))
            registration.touch()
            for kind in ("host", "sync"):
                process = self.start("raise SystemExit('must not run')", kind=kind)
                _, error = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 1, error)
                self.assertIn(b"unreleased test lease", error)
            registration.unlink()  # Explicit owner release, never inferred from process death.
            for kind in ("host", "sync"):
                process = self.start("pass", kind=kind)
                _, error = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, error)

    def test_missing_nested_descriptor_fails_explicitly_instead_of_waiting(self):
        script = ("import subprocess,sys; "
                  f"raise SystemExit(subprocess.call([sys.executable,{str(self.guard)!r},'--kind','sync','--',"
                  "sys.executable,'-c','pass']))")
        process = self.start(script)
        _, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 1)
        self.assertIn(b"did not inherit its lock descriptor", error)

    def test_readonly_child_verifies_the_ancestor_lease_without_an_inherited_descriptor(self):
        script = ("import subprocess,sys; "
                  f"raise SystemExit(subprocess.call([sys.executable,{str(self.guard)!r},'--verify-readonly']))")
        process = self.start(script)
        _, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, error)
