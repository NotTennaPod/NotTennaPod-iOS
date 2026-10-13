"""Synthetic actors prove bounded pipe cancellation and reversible versus terminal stop."""
from __future__ import annotations

import os
import json
import select
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from hub.candidate import ROOT
from hub.events import EventLog
from hub.processes import finish_owned_group, group_members, owned_popen
from hub.web import WebActor, WebError


class WebShutdownTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix="web-shutdown-", dir=ROOT / ".work"))
        self.addCleanup(shutil.rmtree, self.folder)
        self.script = self.folder / "actor.py"
        self.script.write_text(
            "import json,signal,subprocess,sys,threading\n"
            f"sys.path.insert(0,{str(ROOT / 'TestSupport' / 'Servers')!r})\n"
            "from hub.processes import owned_popen\n"
            "child=owned_popen([sys.executable,'-c','import signal; signal.pause()'])\n"
            "for line in sys.stdin:\n"
            " request=json.loads(line)\n"
            " print(json.dumps({'id':request['id'],'ok':True,'result':{'protocol':1,'child':child.pid}}),flush=True)\n"
            " if request['cmd']=='hello' and '--stalled' in sys.argv:\n"
            "  signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            "  threading.Event().wait()\n"
            "print('synthetic actor final tail',file=sys.stderr,flush=True)\n"
            "child.terminate(); child.wait()\n")
        candidate = SimpleNamespace(web_commit="synthetic", web_copy=lambda: self.folder)
        self.actor = WebActor(EventLog(), candidate, self.folder / "web", "http://127.0.0.1")
        self.addCleanup(self.actor.stop, terminal=True)

    def spawn(self, stalled=False):
        def synthetic(_arguments, **options):
            return owned_popen([sys.executable, str(self.script), *( ["--stalled"] if stalled else [])], **options)
        return patch("hub.web.owned_popen", side_effect=synthetic)

    def test_public_stop_allows_restart_and_terminal_stop_refuses_resurrection(self):
        with self.spawn():
            self.actor.call(None, "hello", {})
            first = self.actor.process.pid
            self.actor.stop()
            self.assertEqual(group_members(first), [])
            self.assertIn("synthetic actor final tail", (self.actor.folder / "actor.log").read_text())
            self.actor.call("profile", "open", {})
            second = self.actor.process.pid
            self.assertNotEqual(first, second)
            self.actor.stop(terminal=True)
            self.assertEqual(group_members(second), [])
            with self.assertRaisesRegex(WebError, "shutting down"):
                self.actor.call(None, "hello", {})

    def test_actual_stop_authenticates_renderer_before_eof_exits_browser_leader(self):
        records = self.folder / "surviving-browser"
        synthetic = Path(__file__).with_name("synthetic_browser_creator.py")
        def spawn(_arguments, **options):
            return owned_popen([sys.executable, str(synthetic), "--mode", "web", "--records", str(records)], **options)
        def recovery():
            if (records / "recovery.json").exists():
                finish_owned_group(json.loads((records / "recovery.json").read_text()), timeout=0)
        self.addCleanup(recovery)
        with patch("hub.web.owned_popen", side_effect=spawn):
            hello = self.actor.start()
            initial = json.loads((records / "initial.json").read_text())
            self.assertNotIn(str(hello["renderer"]), initial["members"])
            terminal = self.actor.stop(terminal=True, timeout=0.2)
        cancellation = json.loads((records / "cancel.json").read_text())
        self.assertTrue(cancellation["renderer_authenticated_before_cancel"])
        self.assertTrue(cancellation["browser_leader_exited"])
        self.assertTrue(cancellation["renderer_survived_creator_cleanup"])
        self.assertEqual(group_members(hello["browser"]), [])
        self.assertEqual(group_members(hello["creator"]), [])
        receipt = json.loads(Path(hello["receipt"]).read_text())
        self.assertTrue(receipt["exited"])
        self.assertIn(str(hello["renderer"]), receipt["members"])
        self.assertTrue(any(entry.get("pid") == hello["browser"] and entry["exited"] for entry in terminal["detached_groups"]))
        self.assertIn("synthetic creator final tail", (self.actor.folder / "actor.log").read_text())
        self.assertFalse(self.actor.reader.is_alive())

    def test_full_stdin_pipe_cancels_writer_before_shutdown_stream_close(self):
        with self.spawn(stalled=True):
            self.actor.start()
            process = self.actor.process
            child = self.actor.hello["child"]
            self.assertNotIn(child, group_members(process.pid))
            self.assertIn(child, group_members(child), "synthetic browser is independently detached")
            blocked = threading.Event()
            select_real = select.select
            failures = []

            def select_observed(readers, writers, errors, timeout):
                answer = select_real(readers, writers, errors, timeout)
                if writers and not answer[1]:
                    blocked.set()  # Observable full pipe, not a timing sleep.
                return answer

            def write_command():
                try:
                    self.actor.call(None, "blocked", {"payload": "x" * (8 << 20)})
                except Exception as error:
                    failures.append(error)

            with patch("hub.web.select.select", side_effect=select_observed):
                writer = threading.Thread(target=write_command)
                writer.start()
                self.assertTrue(blocked.wait(5), "large synthetic command never filled the actor pipe")
                terminal = self.actor.stop(terminal=True, timeout=0.2)
                writer.join(5)
            self.assertFalse(writer.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], WebError)
            self.assertTrue(terminal["exited"])
            self.assertEqual(group_members(process.pid), [])
            self.assertEqual(group_members(child), [])
            self.assertFalse(self.actor.reader.is_alive())
            self.assertTrue((self.actor.folder / "actor.log").exists())

