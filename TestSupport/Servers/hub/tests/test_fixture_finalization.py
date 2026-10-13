"""Launcher deadlines cannot hide detached children or treat failed Hub retention as success."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from hub.candidate import ROOT
from hub.processes import finish_owned_group, group_members
from .support import call, free_port

SCRIPT = ROOT / "Tools" / "fixture-process.py"
CONTROLLED = Path(__file__).with_name("controlled_fixture_hub.py")


class FixtureFinalizationTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        self.state = Path(tempfile.mkdtemp(prefix="launcher-finalization-", dir=ROOT / ".work"))
        # Failed finalization intentionally leaves original evidence in .work for diagnosis.
        self.addCleanup(self.cleanup)

    def run_launcher(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), *arguments, "--state", str(self.state)],
                              capture_output=True, text=True, timeout=45)

    def confirm_exits(self):
        for path in [*self.state.glob("*.process.json"), *self.state.glob("*.groups/**/*.json")]:
            entry = json.loads(path.read_text())
            if entry.get("pid"):
                self.assertEqual(group_members(entry["pid"]), [], f"owned synthetic group still exists: {path}")

    def cleanup(self):
        entries = [json.loads(path.read_text()) for path in
                   [*self.state.glob("*.process.json"), *self.state.glob("*.groups/**/*.json")]]
        if any(group_members(entry["pid"]) for entry in entries if entry.get("pid")):
            self.run_launcher("stop", "--shutdown-timeout", "0.2")
        self.confirm_exits()

    def start(self, failure):
        port = free_port()
        run = self.state / "controlled"
        result = subprocess.run([sys.executable, str(SCRIPT), "launch", "--state", str(self.state),
                                 "--name", "ntp-server", "--port", str(port), "--", sys.executable,
                                 str(CONTROLLED), "--run-dir", str(run), "--port", str(port), "--failure", failure],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        deadline = time.monotonic() + 10
        condition = threading.Event()
        while not (run / "health-ready").exists():
            self.assertLess(time.monotonic(), deadline, "controlled Hub never passed Server health readiness")
            condition.wait(0.02)
        return run, port

    def test_supervisor_deadline_finalizes_detached_groups_but_fails_without_terminal_receipt(self):
        run, _port = self.start("blocked-startup")
        stopped = self.run_launcher("stop", "--shutdown-timeout", "0.2")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertTrue((self.state / "ntp-server.pid").exists())
        self.assertTrue((self.state / "ntp-server.process.json").exists())
        self.assertTrue(list((self.state / "ntp-server.groups").rglob("*.json")))
        receipt = json.loads((self.state / "retained.json").read_text())
        self.assertFalse(receipt["quiesced"])
        self.assertIn("controlled primary failure retained", (self.state / "ntp-server.log").read_text())
        self.assertTrue((run / "run" / "events.jsonl").exists())
        self.confirm_exits()

    def test_retention_failure_keeps_primary_error_originals_and_owned_receipts(self):
        run, port = self.start("retention")
        status, answer = call(f"http://127.0.0.1:{port}", "GET", "/ready", timeout=5)
        self.assertEqual(status, 200, answer)
        stopped = self.run_launcher("stop", "--shutdown-timeout", "10")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("incomplete finalization", stopped.stderr)
        terminal = json.loads((run / "run" / "terminal.json").read_text())
        self.assertTrue(terminal["retention_failed"])
        self.assertEqual(terminal["primary_error"], "controlled primary failure retained")
        self.assertTrue((run / "run" / "server" / "server.log").exists())
        self.assertTrue((self.state / "ntp-server.process.json").exists())
        self.assertFalse(json.loads((self.state / "retained.json").read_text())["quiesced"])
        self.confirm_exits()

    def test_actual_launcher_stop_preflights_renderer_before_supervisor_signal(self):
        records = self.state / "surviving-browser"
        synthetic = Path(__file__).with_name("synthetic_browser_creator.py")
        def recovery():
            if (records / "recovery.json").exists():
                finish_owned_group(json.loads((records / "recovery.json").read_text()), timeout=0)
        self.addCleanup(recovery)
        launched = subprocess.run([sys.executable, str(SCRIPT), "launch", "--state", str(self.state),
                                   "--name", "synthetic", "--", sys.executable, str(synthetic),
                                   "--mode", "signal", "--records", str(records)],
                                  capture_output=True, text=True, timeout=10)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        deadline, condition = time.monotonic() + 5, threading.Event()
        while not (records / "ready.json").exists():
            self.assertLess(time.monotonic(), deadline, "synthetic creator never registered its renderer")
            condition.wait(0.02)
        ready = json.loads((records / "ready.json").read_text())
        initial = json.loads((records / "initial.json").read_text())
        self.assertNotIn(str(ready["renderer"]), initial["members"])
        stopped = self.run_launcher("stop", "--shutdown-timeout", "0.2")
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        cancelled = json.loads((records / "cancel.json").read_text())
        self.assertTrue(cancelled["renderer_authenticated_before_cancel"])
        self.assertTrue(cancelled["browser_leader_exited"])
        self.assertTrue(cancelled["renderer_survived_creator_cleanup"])
        self.assertEqual(group_members(ready["browser"]), [])
        self.assertEqual(group_members(ready["creator"]), [])
        retained = json.loads((self.state / "retained.json").read_text())
        self.assertTrue(retained["quiesced"])
        self.assertTrue(any(entry.get("pid") == ready["browser"] and entry["exited"] for entry in retained["children"]))
        self.assertIn("synthetic creator final tail", (Path(retained["evidence"]) / "private" / "synthetic.log").read_text())
        self.assertFalse((self.state / "synthetic.process.json").exists())
        self.assertFalse((self.state / "synthetic.groups").exists())
