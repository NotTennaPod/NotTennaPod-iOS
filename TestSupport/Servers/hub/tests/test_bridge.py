"""The event log's waits and filters, the app bridge (hello, reports, the crash receipt, commands, the kill and the
confirmed exit) and the 2I transplant's copy rules."""

from __future__ import annotations

import ctypes
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from hub import transplant
from hub.bridge import AppBridge
from hub.events import EventLog


class EventLogTests(unittest.TestCase):
    def test_filters_and_waits(self) -> None:
        log = EventLog()
        log.emit("proxy", "request", status=503, path="/v1/push")
        log.emit("app", "save", position_ms=5000, durable=False)
        self.assertEqual(len(log.select(0, {"status": "503"})), 1)
        self.assertEqual(len(log.select(0, {"path": "/v1/*"})), 1)
        self.assertEqual(len(log.select(0, {"kind": ["save", "export"]})), 1)
        self.assertEqual(len(log.select(0, {"durable": "false"})), 1)
        self.assertEqual(log.select(1, {}), log.select(0, {"source": "app"}))
        self.assertIsNone(log.wait(2, {"kind": "export"}, timeout=0.1))
        threading.Timer(0.1, lambda: log.emit("app", "export", type="session.checkpoint")).start()
        self.assertEqual(log.wait(2, {"kind": "export"}, timeout=5)[0]["seq"], 3)

    def test_the_file_holds_one_event_per_line(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            log = EventLog(Path(folder) / "events.jsonl")
            log.emit("server", "started", pid=1)
            log.emit("server", "stopped", pid=1, reason=None)
            log.close()
            lines = (Path(folder) / "events.jsonl").read_text().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertNotIn("reason", lines[1])


class AppBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events = EventLog()
        self.bridge = AppBridge(self.events)

    def tearDown(self) -> None:
        self.bridge.stop()

    def test_reports_the_crash_receipt_before_answering_and_runs_commands(self) -> None:
        self.bridge.hello({"session": "s1", "pid": os.getpid(), "crash_at": "push.barrier"})
        self.bridge.report({"session": "s1", "kind": "crash_point", "point": "pull.spooled", "armed": False})
        receipt = self.bridge.crash({"session": "s1", "point": "push.barrier"})["receipt"]
        event = self.events.select(0, {"kind": "crash_point", "armed": True})[0]
        self.assertEqual((event["seq"], event["point"], event["pid"]), (receipt, "push.barrier", os.getpid()))
        with self.assertRaises(ValueError):
            self.bridge.report({"kind": "anything"})

        def app() -> None:
            commands = self.bridge.poll("s1", 0, timeout=10)
            self.bridge.done(commands[0]["id"], {"ok": True, "result": {"expired": commands[0]["args"]["lease"]}})

        threading.Thread(target=app, daemon=True).start()
        result = self.bridge.command({"command": "expire_lease", "lease": "grant-1", "timeout": 10})
        self.assertEqual(result, {"ok": True, "result": {"expired": "grant-1"}})
        self.assertEqual(self.events.select(0, {"kind": "command"})[0]["command"], "expire_lease")
        with self.assertRaises(TimeoutError):
            self.bridge.command({"command": "run_background_refresh", "timeout": 0.2})
        with self.assertRaises(TimeoutError):
            self.bridge.command({"command": "run_server_sync", "work": "processing", "timeout": 0.2})

    def test_keeps_the_apps_action_clock_offset_with_its_session(self) -> None:
        self.bridge.hello({"session": "s3", "pid": os.getpid(), "library": "LIB-1", "clock_offset_ms": 259200000})
        self.bridge.hello({"session": "s4", "pid": os.getpid(), "library": "LIB-1", "clock_offset_ms": -259200000})
        self.bridge.hello({"session": "s5", "pid": os.getpid(), "library": "LIB-2"})
        hellos = self.events.select(0, {"kind": "hello"})
        self.assertEqual([event.get("clock_offset_ms") for event in hellos], [259200000, -259200000, None])
        sessions = {entry["session"]: entry for entry in self.bridge.describe()["sessions"]}
        self.assertEqual((sessions["s3"]["clock_offset_ms"], sessions["s3"]["library"]), (259200000, "LIB-1"))

    def test_a_clock_offset_is_a_json_integer_or_the_hello_is_refused(self) -> None:
        for invalid in (1.25, 1.0, True, False, "259200000", "three days", [1], {"ms": 1}):
            with self.assertRaises(ValueError, msg=repr(invalid)):
                self.bridge.hello({"session": f"bad-{invalid!r}", "pid": os.getpid(), "clock_offset_ms": invalid})
        self.assertEqual(self.events.select(0, {"kind": "hello"}), [], "a refused hello records nothing")
        self.assertEqual(self.bridge.describe()["sessions"], [])

    def test_kills_the_app_and_confirms_its_exit(self) -> None:
        stand_in = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"])
        try:
            self.bridge.hello({"session": "s2", "pid": stand_in.pid})
            result = self.bridge.kill({"reason": "a save after an export"})
            self.assertTrue(result["exited"])
            self.assertEqual(stand_in.wait(5), -9)
            self.assertEqual(self.events.select(0, {"kind": "exited"})[0]["pid"], stand_in.pid)
        finally:
            stand_in.kill()


def set_excluded(path: Path) -> None:
    libc = ctypes.CDLL(None)
    value = b"com.apple.backupd"
    assert libc.setxattr(os.fsencode(path), transplant.EXCLUDE_XATTR, value, len(value), 0, 0) == 0


class TransplantTests(unittest.TestCase):
    def make_library(self, root: Path, marker: str) -> None:
        support = root / "Library" / "Application Support" / "UITests-A"
        server = support / "Server Libraries" / "lib-1"
        (server / "staging" / "pull").mkdir(parents=True)
        (server / "media").mkdir(parents=True)
        (server / "staging" / "pull" / "page-000001.json").write_text("{}")
        (server / "media" / "episode.mp3").write_bytes(b"audio-" + marker.encode())
        (support / "libraries.json").write_text(marker)
        (support / "excluded.bin").write_text("cache")
        set_excluded(support / "excluded.bin")
        for database in (support / "library.sqlite", server / "sync.sqlite"):
            connection = sqlite3.connect(database)
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE IF NOT EXISTS t(v TEXT)")
            connection.execute("INSERT INTO t VALUES (?)", (marker,))
            connection.commit()
            # Left open on purpose: the WAL holds the row, as after a SIGKILL.
            self.addCleanup(connection.close)
        (root / "Documents").mkdir(parents=True, exist_ok=True)
        (root / "Documents" / "export.db").write_bytes(b"not sqlite but kept")

    def test_copies_databases_with_their_wal_and_leaves_out_staging_and_excluded_files(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            source, target = Path(folder) / "phone", Path(folder) / "tablet"
            self.make_library(source, "phone")
            self.make_library(target, "tablet-old")
            support = Path("Library") / "Application Support" / "UITests-A"
            self.assertTrue((source / support / "library.sqlite-wal").stat().st_size > 0)
            report = transplant.copy_tree(source / support, target / support)
            self.assertIn("Server Libraries/lib-1/staging", report["left_out"])
            self.assertIn("excluded.bin", report["left_out"])
            self.assertFalse((target / support / "Server Libraries" / "lib-1" / "staging").exists())
            self.assertFalse((target / support / "excluded.bin").exists())
            self.assertEqual((target / support / "Server Libraries" / "lib-1" / "media" / "episode.mp3").read_bytes(), b"audio-phone")
            for database in (target / support / "library.sqlite", target / support / "Server Libraries" / "lib-1" / "sync.sqlite"):
                copied = sqlite3.connect(database)
                self.assertEqual(copied.execute("SELECT v FROM t").fetchall(), [("phone",)], database)
                copied.close()
            self.assertFalse(list((target / support).rglob(".transplant-*")))

    def test_refuses_to_copy_a_tree_onto_itself_or_into_itself_and_changes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "phone"
            self.make_library(source, "phone")
            support = source / "Library" / "Application Support"
            before = sorted(str(path.relative_to(source)) for path in source.rglob("*"))
            link = Path(folder) / "same"
            link.symlink_to(support)
            for target in (support, link, support / "UITests-A", support.parent):
                with self.assertRaises(ValueError, msg=str(target)):
                    transplant.copy_tree(support, target)
            self.assertEqual(sorted(str(path.relative_to(source)) for path in source.rglob("*")), before)
            database = sqlite3.connect(support / "UITests-A" / "library.sqlite")
            self.assertEqual(database.execute("SELECT v FROM t").fetchall(), [("phone",)])
            database.close()

    def test_refuses_the_same_installation_by_another_name_before_touching_anything(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            container = Path(folder) / "container"
            self.make_library(container, "phone")
            before = sorted(str(path.relative_to(container)) for path in container.rglob("*"))
            names = {"Sample-iPhone": "UDID-1", "UDID-1": "UDID-1", "UDID-2": "UDID-2"}
            with mock.patch.object(transplant, "simulator", side_effect=lambda name: names[name]), \
                 mock.patch.object(transplant, "container", side_effect=lambda udid, bundle=transplant.BUNDLE: container):
                with self.assertRaises(ValueError):
                    transplant.transplant("Sample-iPhone", "UDID-1")
                with self.assertRaises(ValueError):  # two devices whose containers are one folder
                    transplant.transplant("UDID-1", "UDID-2")
            self.assertEqual(sorted(str(path.relative_to(container)) for path in container.rglob("*")), before)

    def test_finds_an_installed_app_on_a_simulator(self) -> None:
        devices = [path for path in transplant.DEVICES.glob("*") if path.is_dir()] if transplant.DEVICES.exists() else []
        for device in devices:
            try:
                found = transplant.container(device.name)
            except LookupError:
                continue
            self.assertTrue((found / "Library").is_dir())
            return
        self.skipTest("NotTennaPod is installed on no Simulator")


if __name__ == "__main__":
    unittest.main()


class SummaryTests(unittest.TestCase):
    def test_every_clock_offset_of_the_run_is_listed(self) -> None:
        from hub.summary import clock_offsets
        events = [
            {"seq": 2, "source": "server", "kind": "started", "pid": 1},
            {"seq": 5, "source": "server", "kind": "clock", "offset": "72h"},
            {"seq": 6, "source": "server", "kind": "started", "pid": 2, "clock_offset": "72h"},
            {"seq": 9, "source": "app", "kind": "hello", "session": "s1", "pid": 3, "library": "LIB-1",
             "clock_offset_ms": 259200000},
            {"seq": 12, "source": "app", "kind": "hello", "session": "s2", "pid": 4, "library": "LIB-1"},
        ]
        lines = clock_offsets(events)
        self.assertEqual(len(lines), 3, lines)
        self.assertIn("72h", lines[0])
        self.assertIn("72h", lines[1])
        self.assertIn("259200000", lines[2])
        self.assertIn("LIB-1", lines[2])
        self.assertIn("s1", lines[2])
