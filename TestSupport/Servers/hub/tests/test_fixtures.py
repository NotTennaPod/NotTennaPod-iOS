"""Tools/test-fixtures.sh shares only this checkout's own fixture servers: a listener it did not start is never taken
for one of its own, also with a stale run registry, and a shared hub must be the one this run asked for (its run
folder, when NTP_HUB_RUN_DIR is given, and always its candidate). The script runs with its own state folder and
servers (NTP_FIXTURE_STATE, NTP_FIXTURE_SERVERS) on free ports; the UI tests' fixtures are never touched."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import threading
import unittest
from pathlib import Path

from hub.candidate import ROOT, pinned

from .support import free_port

SCRIPT = ROOT / "Tools" / "test-fixtures.sh"
STUB = Path(__file__).with_name("stub_hub.py")


def accepting(port: int) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


class FixtureLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        (ROOT / ".work").mkdir(exist_ok=True)  # a fresh checkout has none yet
        self.state = Path(tempfile.mkdtemp(prefix="fixture-test-", dir=ROOT / ".work"))
        self.servers: list[str] = []
        self.addCleanup(self.clean)

    def clean(self) -> None:
        stopped = subprocess.run([sys.executable, str(ROOT / "Tools" / "fixture-process.py"), "stop", "--state",
                                  str(self.state)], capture_output=True, text=True, timeout=120)
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        shutil.rmtree(self.state)

    def script(self, action: str, run: str = "manual", hub_run: str | None = None) -> subprocess.CompletedProcess:
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("NTP_HUB_RUN_DIR", "TARGET_DEVICE_IDENTIFIER")}
        environment.update(NTP_FIXTURE_STATE=str(self.state), NTP_FIXTURE_SERVERS="\n".join(self.servers),
                           NTP_FIXTURE_NO_SEED="1")
        if hub_run:
            environment["NTP_HUB_RUN_DIR"] = hub_run
        # A run's registration is named by its device; these runs are named, with no Simulator to seed.
        inherited = environment.get("NTP_VALIDATION_LOCK_FD")
        descriptors = (int(inherited),) if inherited else ()
        return subprocess.run(["/bin/zsh", str(SCRIPT), action, run], capture_output=True, text=True, env=environment,
                              pass_fds=descriptors, timeout=120)

    def registered(self) -> list[str]:
        folder = self.state / "users.d"
        return sorted(path.name for path in folder.iterdir()) if folder.exists() else []

    def wait_closed(self, port: int) -> None:
        deadline = time.monotonic() + 20
        while accepting(port):
            self.assertLess(time.monotonic(), deadline, f"port {port} still accepts")
            threading.Event().wait(0.05)

    def test_a_foreign_listener_is_never_shared_also_with_a_stale_registry(self) -> None:
        foreign = socket.socket()
        foreign.bind(("127.0.0.1", 0))
        foreign.listen()
        self.addCleanup(foreign.close)
        port = foreign.getsockname()[1]
        self.servers = [f"foreign|{port}|{sys.executable} -m http.server {port} --bind 127.0.0.1"]
        (self.state / "users.d").mkdir(parents=True)
        (self.state / "users.d" / "stale-run").touch()  # left by an interrupted run of this checkout
        result = self.script("start", "new-run")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not by this checkout's fixtures", result.stderr)
        self.assertNotIn("new-run", self.registered())

    def test_its_own_servers_are_shared_and_the_last_run_stops_them(self) -> None:
        port = free_port()
        self.servers = [f"plain|{port}|{sys.executable} -m http.server {port} --bind 127.0.0.1"]
        first = self.script("start", "run-a")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.script("start", "run-b")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("shared", second.stdout)
        self.assertEqual(self.registered(), ["run-a", "run-b"])
        self.assertIn("1 run(s) still using", self.script("stop", "run-a").stdout)
        self.assertTrue(accepting(port))
        self.assertIn("stopped", self.script("stop", "run-b").stdout)
        self.wait_closed(port)

    def test_a_shared_hub_must_be_this_runs_hub(self) -> None:
        port = free_port()
        first_run = str(self.state / "acceptance-a" / "hub")
        server, web = pinned("server-version.txt"), pinned("web-version.txt")
        hub = f"ntp-server|{port}|{sys.executable} {STUB} --port {port} --run-dir {first_run} --server-commit {server} --web-commit {web}"
        self.servers = [hub]
        self.assertEqual(self.script("start", "run-a", hub_run=first_run).returncode, 0)
        # Another acceptance run's folder: refused.
        other = self.script("start", "run-b", hub_run=str(self.state / "acceptance-b" / "hub"))
        self.assertNotEqual(other.returncode, 0)
        self.assertIn("run folder", other.stderr)
        # The scheme's pre-action names no folder: it shares the acceptance run's hub.
        self.assertEqual(self.script("start", "run-c").returncode, 0)
        self.assertEqual(self.registered(), ["run-a", "run-c"])
        self.script("stop", "run-a")
        self.script("stop", "run-c")
        self.wait_closed(port)

    def test_a_shared_hub_must_run_the_pinned_server_unconditionally(self) -> None:
        port = free_port()
        run = self.state / "hub"
        run.mkdir()
        mismatched = "1111111111111111111111111111111111111111"
        self.servers = [f"ntp-server|{port}|{sys.executable} {STUB} --port {port} --run-dir {run} "
                        f"--server-commit {pinned('server-version.txt')} --web-commit {pinned('web-version.txt')} "
                        f"--active-commit {mismatched}"]
        self.assertEqual(self.script("start", "run-a").returncode, 0)
        # The configured candidate is right, but the actual running identity differs.
        other = self.script("start", "run-b")
        self.assertNotEqual(other.returncode, 0)
        self.assertIn(mismatched, other.stderr)
        self.assertNotEqual(self.script("start", "run-b").returncode, 0)
        self.assertNotIn("run-b", self.registered())
        self.script("stop", "run-a")
        self.wait_closed(port)

    def test_a_shared_hub_with_another_candidate_is_refused(self) -> None:
        port = free_port()
        self.servers = [f"ntp-server|{port}|{sys.executable} {STUB} --port {port} --run-dir {self.state / 'hub'} "
                        f"--server-commit 0000000000000000000000000000000000000000 --web-commit {pinned('web-version.txt')}"]
        self.assertEqual(self.script("start", "run-a").returncode, 0)
        other = self.script("start", "run-b")
        self.assertNotEqual(other.returncode, 0)
        self.assertIn("candidate", other.stderr)
        self.script("stop", "run-a")
        self.wait_closed(port)


if __name__ == "__main__":
    unittest.main()
