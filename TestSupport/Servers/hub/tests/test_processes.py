"""Forced shutdown must confirm test-owned child and descendant exits."""
from __future__ import annotations

import selectors
import signal
import json
import os
import shutil
import tempfile
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from hub.events import EventLog
from hub.candidate import ROOT
from hub.processes import finish_process, group_members, owned_popen, verify_owned_group, finish_registered_groups, preflight_registered_groups
from hub.server import ServerLifecycle, ServerError


class ProcessFinalizationTests(unittest.TestCase):
    def test_preflight_members_survive_stale_creator_receipt_and_terminal_updates(self):
        from hub.processes import _receipt
        (ROOT / ".work").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".work") as temporary:
            registry = Path(temporary)
            path = registry / "browser.json"
            stale = {"registered": True, "pid": 123, "birth": "owned leader", "members": {"123": "owned leader"}, "exited": False}
            _receipt(path, stale)
            with patch("hub.processes.birth", side_effect=lambda pid, **options: "owned leader" if pid == 123 else "owned renderer"), \
                    patch("hub.processes.group_members", return_value=[123, 124]), patch("hub.processes.os.killpg") as kill:
                preflight_registered_groups(registry)
                kill.assert_not_called()
            _receipt(path, {**stale, "exited": True})
            _receipt(path, stale)  # A delayed preflight cannot undo a confirmed terminal update.
            final = json.loads(path.read_text())
            self.assertEqual(final["members"]["124"], "owned renderer")
            self.assertTrue(final["exited"])

    def test_browser_survivors_exit_when_creator_shutdown_exits_browser_leader(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix="browser-survivor-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, folder)
        script = ("import subprocess,sys,signal\n"
                  "sys.stdin.buffer.readline()\n"
                  "child=subprocess.Popen([sys.executable,'-c',"
                  "'import signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(1,flush=True); signal.pause()'],"
                  "stdout=subprocess.PIPE)\n"
                  "child.stdout.readline()\n"
                  "print(child.pid,flush=True)\n"
                  "signal.pause()\n")
        with patch.dict(os.environ, NTP_FIXTURE_OWNERSHIP_DIR=str(folder)):
            creator = owned_popen([sys.executable, "-c", "import signal; signal.pause()"])
            browser = owned_popen([sys.executable, "-c", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(finish_process, creator, timeout=0)
        self.addCleanup(finish_process, browser, timeout=0)
        browser.stdin.write(b"start renderer\n")
        browser.stdin.flush()
        with selectors.DefaultSelector() as ready:
            ready.register(browser.stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(5), "synthetic browser did not publish renderer readiness")
        renderer = int(browser.stdout.readline())
        self.assertIn(renderer, group_members(browser.pid))
        browser_path = browser._ntp_ownership_path
        entry = json.loads(browser_path.read_text())
        entry["supervisor"] = creator.pid
        browser_path.write_text(json.dumps(entry))
        self.assertNotIn(str(renderer), entry["members"], "renderer appeared after the initial spawn receipt")
        from hub.processes import finish_owned_group
        def creator_exit(current, timeout):
            if current.get("pid") == creator.pid:
                # A cooperative actor shutdown can make the browser leader exit first.
                browser.terminate()
                browser.wait(timeout=5)
                self.assertIn(renderer, group_members(browser.pid))
            return finish_owned_group(current, timeout)
        with patch("hub.processes.finish_owned_group", side_effect=creator_exit):
            finish_registered_groups(folder, timeout=0)
        self.assertEqual(group_members(browser.pid), [])
        self.assertEqual(group_members(creator.pid), [])
        browser.stdin.close()
        browser.stdout.close()

    def test_zombie_only_group_is_exited_but_a_live_refusal_is_still_raised(self):
        from hub.processes import _signal_group, finish_owned_group
        process = subprocess.Popen([sys.executable, "-c", "import signal; signal.pause()"], start_new_session=True)
        self.addCleanup(lambda: finish_process(process, timeout=0))
        process.terminate()
        condition, deadline = threading.Event(), time.monotonic() + 5
        while subprocess.run(["ps", "-o", "stat=", "-p", str(process.pid)], capture_output=True, text=True).stdout.strip()[:1] != "Z":
            self.assertLess(time.monotonic(), deadline, "terminated leader never became an unreaped zombie")
            condition.wait(0.01)
        with self.assertRaises(PermissionError):
            os.killpg(process.pid, 0)  # XNU reports a zombie-only group as EPERM, not ESRCH.
        self.assertEqual(group_members(process.pid), [])
        _signal_group(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        entry = {"registered": True, "pid": 123, "birth": "owned leader", "members": {}, "exited": False}
        with patch("hub.processes.birth", return_value="owned leader"), patch("hub.processes.group_members", return_value=[123]), \
                patch("hub.processes.os.killpg", side_effect=PermissionError(1, "Operation not permitted")):
            with self.assertRaises(PermissionError):
                _signal_group(123, signal.SIGKILL)
            with self.assertRaisesRegex(RuntimeError, r"SIGCONT failed \(errno 1\)"):
                finish_owned_group(entry, timeout=0)

    def test_actor_preload_registers_a_separate_browser_group_before_actor_death(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix="actor-owned-groups-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, folder)
        registry = folder / "groups"
        preload = ROOT / "TestSupport" / "Servers" / "hub" / "actor-process-ownership.cjs"
        script = ("const cp=require('node:child_process');"
                  "const child=cp.spawn(process.execPath,['-e','setInterval(()=>{},100000)'],"
                  "{detached:true,stdio:'ignore'});"
                  "console.log(child.pid);setInterval(()=>{},100000);")
        environment = dict(os.environ, NTP_FIXTURE_OWNERSHIP_DIR=str(registry))
        process = owned_popen(["node", "--require", str(preload), "-e", script],
                              env=environment, stdout=subprocess.PIPE)
        self.addCleanup(finish_registered_groups, registry, timeout=0)
        self.addCleanup(finish_process, process, timeout=0)
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(5))
        browser = int(process.stdout.readline())
        entries = [json.loads(path.read_text()) for path in registry.glob("*.json")]
        self.assertTrue(any(item.get("pid") == browser and item["registered"] and item["birth"] for item in entries))
        self.assertNotIn(browser, group_members(process.pid))
        process.kill()  # Abrupt actor death precedes any cooperative browser.close().
        process.wait(timeout=5)
        self.assertIn(browser, group_members(browser))
        finish_registered_groups(registry, timeout=0)
        self.assertEqual(group_members(browser), [])
        self.assertEqual(group_members(process.pid), [])
        process.stdout.close()

    def test_detached_ownership_survives_supervisor_exit_and_refuses_reused_or_unknown_groups(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        folder = Path(tempfile.mkdtemp(prefix="owned-groups-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, folder)
        with patch.dict(os.environ, NTP_FIXTURE_OWNERSHIP_DIR=str(folder)):
            process = owned_popen([sys.executable, "-c", "import signal; print('ready',flush=True); signal.pause()"],
                                  stdout=subprocess.PIPE)
        self.addCleanup(finish_process, process, timeout=0)
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(5))
        self.assertEqual(process.stdout.readline(), b"ready\n")
        path = next(folder.glob("*.json"))
        entry = json.loads(path.read_text())
        self.assertEqual(entry["pid"], process.pid)
        with patch("hub.processes.birth", return_value="different birth"), patch("hub.processes.os.killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "reused"):
                preflight_registered_groups(folder)
            with self.assertRaisesRegex(RuntimeError, "reused"):
                finish_registered_groups(folder)
            kill.assert_not_called()
        self.assertFalse(json.loads(path.read_text())["exited"])
        terminals = finish_registered_groups(folder)
        self.assertTrue(terminals[0]["exited"])
        process.wait(timeout=5)
        self.assertEqual(group_members(process.pid), [])
        process.stdout.close()
        unresolved = folder / "unresolved.json"
        unresolved.write_text('{"registered": false}')
        with patch("hub.processes.os.killpg") as kill:
            with self.assertRaisesRegex(RuntimeError, "registration is incomplete"):
                preflight_registered_groups(folder)
            with self.assertRaisesRegex(RuntimeError, "registration is incomplete"):
                finish_registered_groups(folder)
            kill.assert_not_called()

    def test_forced_actor_shutdown_reaps_parent_and_removes_descendants(self):
        script = ("import signal,subprocess,sys\n"
                  "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                  "child=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()'])\n"
                  "print(child.pid,flush=True)\n"
                  "signal.pause()\n")
        process = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, start_new_session=True)
        self.addCleanup(lambda: finish_process(process, timeout=0))
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(5), "synthetic actor did not publish child readiness")
        child = int(process.stdout.readline())
        self.assertIn(child, group_members(process.pid))
        terminal = finish_process(process, timeout=0)
        self.assertTrue(terminal["forced"])
        self.assertTrue(terminal["exited"])
        self.assertIsNotNone(process.returncode)
        self.assertEqual(group_members(process.pid), [])
        process.stdout.close()

    def test_shutdown_cancels_and_joins_a_queued_restart(self):
        from pathlib import Path
        server = ServerLifecycle(EventLog(), None, Path("unused-controlled-folder"))
        result = []
        def queued_restart():
            server.closing.wait()
            try:
                server.start(reason="controlled queued restart")
            except ServerError as error:
                result.append(str(error))
        server.restarting = threading.Thread(target=queued_restart)
        server.restarting.start()
        terminal = server.shutdown()
        self.assertTrue(terminal["restart_thread_exited"])
        self.assertFalse(server.restarting.is_alive())
        self.assertEqual(result, ["the server lifecycle is shutting down"])
        self.assertIsNone(server.process)
