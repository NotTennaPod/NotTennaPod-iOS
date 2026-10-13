"""Focused cleanup/evidence checks. Synthetic child failures are expected local test outcomes."""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from hub.candidate import ROOT
from hub.control import Hub
from hub.evidence import retain
from .test_lifecycle import IsolatedHubTestCase
from .support import call


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix="evidence-test-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, self.folder)
        # Deliberately failed synthetic Hub receipts belong to this negative-path test, rather
        # than an outer host invocation's ordinary Hub acceptance registry.
        environment = patch.dict(os.environ, NTP_HUB_TERMINAL_REGISTRY=str(self.folder / "controlled-hubs"),
                                 NTP_FIXTURE_TERMINAL_PATH="")
        environment.start()
        self.addCleanup(environment.stop)

    def test_allowlisted_snapshot_excludes_recovery_inputs_and_free_form_secrets(self):
        run = self.folder / "run"
        (run / "server" / "data").mkdir(parents=True)
        (run / "server" / "server.log").write_text("password=private-value\nfinal-child-line\n")
        (run / "server" / "keys.bundle").write_text("private-key")
        (run / "server" / "passphrase").write_text("private-passphrase")
        (run / "server" / "data" / "setup-code").write_text("private-setup")
        (run / "events.jsonl").write_text(json.dumps({"seq": 1, "source": "hub", "kind": "failed",
                                                      "error": "password=private-value", "token": "private-token"}) + "\n")
        target = retain(run, self.folder / "retained", "test-method", {"server_commit": "server", "web_commit": "web"},
                        {"quiesced": True}, "original assertion")
        raw = target / "private"
        shared = "".join(path.read_text() for path in (target / "shareable").iterdir())
        self.assertIn("final-child-line", (raw / "server" / "server.log").read_text())
        self.assertNotIn("private-value", shared)
        self.assertNotIn("private-token", shared)
        self.assertEqual(json.loads((raw / "receipt.json").read_text())["primary_error"], "original assertion")
        self.assertEqual({str(path.relative_to(raw)) for path in raw.rglob("*") if path.is_file()},
                         {"events.jsonl", "server/server.log", "receipt.json"})
        self.assertEqual(raw.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in raw.rglob("*") if path.is_file()))

    def test_unique_receipts_report_missing_and_truncated_evidence(self):
        run = self.folder / "run"
        run.mkdir()
        (run / "events.jsonl").write_text('{"seq":1')
        targets = [retain(run, self.folder / "retained", "same-method", {}, {"quiesced": False}) for _ in range(2)]
        self.assertNotEqual(*targets)
        receipt = json.loads((targets[0] / "private" / "receipt.json").read_text())
        self.assertTrue(any(item["issue"] == "missing" for item in receipt["issues"]))
        self.assertTrue(any("truncated" in item["issue"] for item in receipt["issues"]))
        self.assertFalse(receipt["terminal"]["quiesced"])

    def test_hub_joins_inflight_listener_changes_before_retaining_terminal_events(self):
        for component, creation in (("publisher", "_listen"), ("proxy", "_open_listener")):
            with self.subTest(component=component):
                hub = Hub(self.folder / component, control_port=0, proxy_port=0, server_port=0, publisher_port=0,
                          keep=True, identity=self.id() + "." + component)
                self.addCleanup(hub.stop)
                hub.publisher.start()
                hub.proxy.start()
                hub.proxy.server_changed(True)
                target = getattr(hub, component)
                target.set_state("refuse")
                decided, release, arrivals_closed = threading.Event(), threading.Event(), threading.Event()
                self.addCleanup(release.set)
                original = getattr(target, creation)
                begin = hub.control.begin_quiesce
                results, errors = [], []

                def paused_creation():
                    decided.set()
                    if not release.wait(5):
                        raise TimeoutError("controlled listener transition was not released")
                    original()

                def close_arrivals():
                    begin()
                    arrivals_closed.set()

                def request():
                    try:
                        call(f"http://127.0.0.1:{hub.control.server_address[1]}", "POST", f"/{component}/state",
                             {"state": "pass"}, timeout=5)
                    except (OSError, ConnectionError):
                        pass  # Shutdown cancels this request's socket while its handler is joined.

                def shutdown():
                    try:
                        results.append(hub.stop(primary_error="controlled primary assertion"))
                    except Exception as error:
                        errors.append(error)

                serving = threading.Thread(target=hub.control.serve_forever, kwargs={"poll_interval": 0.05})
                serving.start()
                with patch.object(target, creation, side_effect=paused_creation), \
                     patch.object(hub.control, "begin_quiesce", side_effect=close_arrivals), \
                     patch("hub.control.ROOT", self.folder):
                    changing = threading.Thread(target=request)
                    changing.start()
                    self.assertTrue(decided.wait(5))
                    stopping = threading.Thread(target=shutdown)
                    stopping.start()
                    self.assertTrue(arrivals_closed.wait(5))
                    release.set()
                    changing.join(5)
                    stopping.join(10)
                serving.join(5)
                self.assertFalse(changing.is_alive())
                self.assertFalse(stopping.is_alive())
                self.assertFalse(serving.is_alive())
                self.assertEqual(errors, [])
                self.assertTrue(results[0]["quiesced"])
                self.assertIsNone(hub.publisher.server)
                self.assertIsNone(hub.proxy.listener)
                self.assertFalse(hub.control.workers)
                events = hub.events.select()
                self.assertEqual(events[-1]["kind"], "stopped")
                self.assertEqual(events[-1]["source"], "hub")
                retained = [json.loads(line) for line in (hub.retained / "private" / "events.jsonl").read_text().splitlines()]
                self.assertEqual(retained, events, "all in-flight worker events precede the retained terminal event")

    def test_startup_child_failure_is_finalized_before_logs_and_data_cleanup(self):
        binary = self.folder / "failed-server"
        binary.write_text(f"#!{sys.executable}\nprint('private child failure')\nprint('complete child tail')\nraise SystemExit(13)\n")
        binary.chmod(0o700)
        hub = Hub(self.folder / "run", control_port=0, proxy_port=0, server_port=0, publisher_port=0,
                  identity=self.id())
        self.addCleanup(hub.stop)
        hub.candidate._binary = binary
        hub.start()
        original = hub.error
        self.assertIn("exited (13)", original)
        with patch("hub.control.ROOT", self.folder):
            terminal = hub.stop(primary_error="primary assertion survives")
        self.assertTrue(terminal["quiesced"])
        self.assertEqual(hub.server.process.wait(timeout=1), 13)
        self.assertFalse((hub.run / "server").exists())
        receipt = json.loads((hub.retained / "private" / "receipt.json").read_text())
        self.assertEqual(receipt["primary_error"], "primary assertion survives")
        self.assertIn("complete child tail\n", (hub.retained / "private" / "server" / "server.log").read_text())
        events = [json.loads(line) for line in (hub.retained / "private" / "events.jsonl").read_text().splitlines()]
        self.assertEqual(events[-1]["kind"], "stopped")
        self.assertTrue(events[-1]["quiesced"])

    def test_teardown_error_preserves_original_failure_and_original_evidence(self):
        hub = Hub(self.folder / "run", control_port=0, proxy_port=0, server_port=0, publisher_port=0, identity=self.id())
        # No component was started. One controlled teardown error is local, not a suite failure.
        with patch.object(hub.server, "shutdown", side_effect=RuntimeError("controlled teardown error")), \
             patch("hub.control.ROOT", self.folder):
            with self.assertRaisesRegex(RuntimeError, "controlled teardown error"):
                hub.stop(primary_error="primary startup error")
        receipt = json.loads((hub.retained / "private" / "receipt.json").read_text())
        self.assertEqual(receipt["primary_error"], "primary startup error")
        self.assertFalse(receipt["terminal"]["quiesced"])
        self.assertTrue((hub.run / "events.jsonl").exists())

    def test_cleanup_is_registered_before_construction_failure(self):
        observed = []

        class Controlled(IsolatedHubTestCase):
            def runTest(self):
                pass

        case = Controlled()
        def fail_construction(*args, **kwargs):
            observed.append((case.folder, len(case._cleanups)))
            raise RuntimeError("controlled construction failure")

        with patch("hub.tests.test_lifecycle.Hub", side_effect=fail_construction), \
             patch("hub.tests.test_lifecycle.ROOT", self.folder):
            result = unittest.TestResult()
            case.run(result)
        self.assertEqual(len(result.errors), 1)
        self.assertIn("controlled construction failure", result.errors[0][1])
        self.assertEqual(observed[0][1], 1)
        self.assertFalse(observed[0][0].exists())
        receipts = list((self.folder / ".work" / "hub-evidence").glob("*/*/private/receipt.json"))
        self.assertEqual(len(receipts), 1)
        self.assertIn("controlled construction failure", json.loads(receipts[0].read_text())["primary_error"])

    def test_capture_failure_records_primary_error_and_keeps_originals(self):
        hub = Hub(self.folder / "run", control_port=0, proxy_port=0, server_port=0, publisher_port=0, identity=self.id())
        (hub.run / "server").mkdir()
        (hub.run / "server" / "server.log").write_text("complete original log\n")
        with patch("hub.control.retain", side_effect=OSError("controlled capture failure")):
            with self.assertRaisesRegex(RuntimeError, "controlled capture failure"):
                hub.stop(primary_error="primary assertion")
        terminal = json.loads((hub.run / "terminal.json").read_text())
        self.assertEqual(terminal["primary_error"], "primary assertion")
        self.assertTrue(terminal["retention_failed"])
        self.assertEqual((hub.run / "server" / "server.log").read_text(), "complete original log\n")
