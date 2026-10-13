"""The whole hub with the release candidate, through its control API: the server's lifecycle (stop, crash, hang and
resume, backup and restore, wipe, the clock offset, the witness), a fault on a real push,
R's listening resolved into the queue by the server, the publisher's private feed reached by the server, and the
web actor's protocol check."""

from __future__ import annotations

import json
import copy
import shutil
import tempfile
import threading
import unittest
import uuid
from pathlib import Path

from hub.candidate import ROOT
from hub.control import Hub

from .support import call, get, raw

PASSWORD = "hub-test-password-1"


class IsolatedHubTestCase(unittest.TestCase):
    def setUp(self) -> None:
        (ROOT / ".work").mkdir(exist_ok=True)  # a fresh checkout has none yet
        self.folder = Path(tempfile.mkdtemp(prefix="hub-test-", dir=ROOT / ".work"))
        self.hub = None
        self.primary_error = None
        self.addCleanup(self.clean)  # registered before construction/build/readiness can fail
        try:
            self.hub = Hub(self.folder / "run", control_port=0, proxy_port=0, server_port=0, publisher_port=0,
                           identity=self.id())
            threading.Thread(target=self.hub.control.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
            self.base = f"http://127.0.0.1:{self.hub.control.server_address[1]}"
            self.hub.launch()
            status, answer = call(self.base, "GET", "/ready", timeout=900)
            self.assertEqual(status, 200, answer)
        except BaseException as error:
            self.primary_error = f"{type(error).__name__}: {error}"
            raise

    def clean(self) -> None:
        # unittest has recorded method failures before running cleanups. Preserve them in the private receipt;
        # a cleanup failure is additionally reported by unittest, never substituted for the original failure.
        result = getattr(self._outcome, "result", None)
        if result:
            failures = [text for test, text in [*result.errors, *result.failures] if test is self]
            self.primary_error = self.primary_error or "\n".join(failures) or None
        if self.hub:
            self.hub.stop(primary_error=self.primary_error)
            shutil.rmtree(self.folder)
        else:
            from hub.evidence import retain
            from hub.candidate import pinned
            retain(self.folder / "run", ROOT / ".work" / "hub-evidence", self.id(),
                   {"server_commit": pinned("server-version.txt"), "web_commit": pinned("web-version.txt")},
                   {"quiesced": True, "construction_failed": True}, self.primary_error)
            shutil.rmtree(self.folder)

    def post(self, path: str, body: dict | None = None, expect: int = 200, timeout: float = 600) -> dict:
        status, answer = call(self.base, "POST", path, body or {}, timeout=timeout)
        self.assertEqual(status, expect, f"{path}: {answer}")
        return answer

    def public(self, path: str, timeout: float = 5.0) -> tuple[str, bytes]:
        return raw(self.hub.proxy.port, get(path), timeout)

    def sign_in(self, username: str, password: str = PASSWORD) -> int:
        """A web sign-in through the proxy: 200 when the account exists with that password."""
        import json
        body = json.dumps({"username": username, "password": password}).encode()
        outcome, data = raw(self.hub.proxy.port, get("/v1/auth/web", "POST", body, {"Origin": "http://127.0.0.1"}))
        return int(data.split(b" ")[1]) if outcome == "answer" else 0

    def seed_library(self) -> dict:
        """Each continuity scenario owns a populated library, facts, queue/history and sealed credentials."""
        account = self.post("/accounts", {"username": "lifecycle-listener", "password": PASSWORD,
                                          "import": "TestSupport/Data/subscriptions-screen/databases/mixed.db"}, 201)
        self.assertEqual(account["import"]["status"], "published")
        client = self.hub.client("continuity")
        client.login(account["username"], PASSWORD)
        episodes = client.episodes()
        self.assertTrue(episodes, "continuity cannot be established on an empty library")
        episode = next(item for item in episodes if item["title"] and not item["in_queue"])
        before_history = copy.deepcopy(client.value("episode", episode["episode_id"], "history"))
        started = client.play(episode["episode_id"], 2000)
        self.assert_receipt(started["results"], "session.start")
        session = started["session"]
        client.pull()
        self.assertTrue(next(item for item in client.episodes() if item["episode_id"] == episode["episode_id"])["in_queue"])
        self.assert_receipt(client.checkpoint(session, 4500)["results"], "session.checkpoint")
        client.pull()
        checkpoint = next(item for item in client.episodes() if item["episode_id"] == episode["episode_id"])
        self.assertEqual(checkpoint["played_ms"], episode["played_ms"] + 2500, "checkpoint adds its known listening contribution")
        self.assertEqual(checkpoint["position"], 4500)
        self.assert_receipt(client.end(session, 5000, False)["results"], "session.end")
        client.pull()
        known = next(item for item in client.episodes() if item["episode_id"] == episode["episode_id"])
        self.assertTrue(known["in_queue"])
        self.assertEqual(known["played_ms"], episode["played_ms"] + 3000, "end replaces the session contribution with 3000 ms")
        self.assertEqual(known["position"], 5000)
        podcast = episode["podcast_id"]
        generation = client.value("podcast", podcast, "subscription")["generation_id"]
        history = client.value("episode", episode["episode_id"], "history")
        self.assertIsInstance(history, dict)
        self.assertEqual(history["generation_id"], generation)
        self.assertGreater(history["time"], (before_history or {}).get("time", 0), "the seeded listening writes newer history")
        secret = str(uuid.uuid4())
        credentials = {"secret_id": secret, "username": "fixture-listener", "password": "fixture-private-secret",
                       "approved_origins": ["https://example.test:443"]}
        client._fact("podcast.set_credentials", {"entity": "podcast", "id": podcast, "generation": generation},
                     {"secret_id": secret})
        self.assertEqual([item["status"] for item in client.push(secrets=[credentials])], ["accepted"])
        client.pull()
        readback = client.send("GET", f"/v1/secrets/{secret}")
        for field in ("username", "password", "approved_origins"):
            self.assertEqual(readback.get(field), credentials[field], f"seeded secret {field} matches its independent input")
        return {"account": account, "client": client, "records": copy.deepcopy(client.records),
                "secret": secret, "credentials": readback}

    def assert_receipt(self, results: list[dict], fact_type: str) -> None:
        self.assertEqual([(item.get("status"), item.get("type")) for item in results], [("accepted", fact_type)],
                         "exactly one accepted receipt for the supplied listening fact")

    def assert_library(self, seed: dict) -> None:
        self.assertEqual(self.sign_in(seed["account"]["username"]), 200)
        client = seed["client"]
        client.records.clear()
        client.attach()
        self.assertEqual(client.account["account_id"], seed["account"]["account_id"])
        # `refresh_status` is the server's own refresh progress (PROTOCOL §9.6): the restarted server keeps
        # refreshing the imported feeds and publishes each new outcome, so it may gain records on its own schedule.
        # Everything the person owns must survive exactly; refresh progress must not be lost.
        def library(records: dict) -> dict:
            return {key: value for key, value in records.items() if key[2] != "refresh_status"}
        self.assertEqual(library(client.records), library(seed["records"]),
                         "same account/library, queue, listening and history survive")
        self.assertLessEqual({key for key in seed["records"] if key[2] == "refresh_status"},
                             {key for key in client.records if key[2] == "refresh_status"},
                             "the server's refresh progress survives")
        self.assertEqual(client.send("GET", f"/v1/secrets/{seed['secret']}"), seed["credentials"])


class LifecycleTests(IsolatedHubTestCase):

    def test_stop_crash_hang_and_resume(self) -> None:
        seed = self.seed_library()
        self.post("/server/stop")
        self.assertEqual(self.public("/v1/info")[0], "refused")
        self.post("/server/start")
        self.assertEqual(self.public("/v1/info")[0], "answer")
        mark = self.hub.events.last
        self.post("/server/crash")
        self.assertTrue(self.hub.events.select(mark, {"kind": "crashed"}))
        self.assertTrue(self.hub.events.select(mark, {"kind": "started", "reason": "restart after crash"}))
        self.assertEqual(self.public("/v1/info")[0], "answer")
        self.post("/server/hang")
        result: dict = {}
        waiting = threading.Thread(target=lambda: result.update(answer=self.public("/v1/info", timeout=30)), daemon=True)
        waiting.start()
        self.assertTrue(self.hub.events.wait(mark, {"kind": "hung"}, timeout=5))
        waiting.join(1.0)
        self.assertTrue(waiting.is_alive(), "a hung server answers nothing")
        self.post("/server/resume")
        waiting.join(30)
        self.assertEqual(result["answer"][0], "answer", "the request held open is answered once the server resumes")
        self.assert_library(seed)

    def test_backup_restore_and_wipe(self) -> None:
        seed = self.seed_library()
        kept = seed["account"]["username"]
        self.post("/server/backup", {"name": "B1"})
        later = self.post("/accounts", {"password": PASSWORD}, 201)["username"]
        self.assertEqual(self.sign_in(later), 200)
        self.post("/server/restore", {"name": "B1"})
        self.assertEqual(self.sign_in(kept), 200)
        self.assertEqual(self.sign_in(later), 401, "the account made after the backup is gone")
        seed["client"].login(kept, PASSWORD)  # a restore may legitimately revoke the pre-restore credential
        self.assert_library(seed)
        self.post("/server/wipe")
        self.assertEqual(self.sign_in(kept), 401)
        self.post("/accounts", {"password": PASSWORD}, 201)

    def test_clock_offset_reset_and_nonempty_witness(self) -> None:
        seed = self.seed_library()
        self.post("/server/clock", {"offset": "72h"})
        log = (self.hub.server.log_path).read_text()
        self.assertIn("--dev-clock-offset 72h", log)
        self.assertIn("the server's clock is moved", log)
        self.assertEqual(self.hub.events.select(0, {"kind": "started"})[-1]["clock_offset"], "72h")
        self.post("/server/clock", {"offset": None})
        starts = self.hub.events.select(0, {"kind": "started"})
        self.assertNotIn("clock_offset", starts[-1], "the offset was cleared")
        invocation = self.hub.server.log_path.read_text().rsplit("--- start ", 1)[-1].splitlines()[0]
        self.assertNotIn("--dev-clock-offset", invocation)
        self.assert_library(seed)
        witness = self.post("/server/witness", timeout=1800)
        self.assertTrue(witness["passed"], Path(witness["log"]).read_text()[-2000:])
        self.assertEqual(self.public("/v1/info")[0], "answer")
        self.assert_library(seed)

    def test_r_listens_and_the_server_queues_through_a_crash_after_the_push(self) -> None:
        account = self.post("/accounts", {"password": PASSWORD,
                                          "import": "TestSupport/Data/subscriptions-screen/databases/mixed.db"}, 201)
        self.assertEqual(account["import"]["status"], "published")
        known = self.post("/r/r1/login", {"username": account["username"], "password": PASSWORD})
        self.assertFalse(known["capabilities_queue"])
        status, state = call(self.base, "GET", "/r/r1")
        episode = next(item for item in state["episodes"] if item["title"] and not item["in_queue"])
        # The server commits the push and is killed before its answer is relayed; R retries the same slot.
        self.post("/proxy/rules", {"mode": "crash_after", "method": "POST", "path": "/v1/push"})
        status, failed = call(self.base, "POST", "/r/r1/play", {"episode": episode["episode_id"]})
        self.assertNotEqual(status, 200, failed)
        self.assertTrue(self.hub.events.wait(0, {"kind": "started", "reason": "restart after crash"}, timeout=60))
        self.hub.server.await_restart()
        retried = self.hub.client("r1").push()
        self.assertEqual([result["status"] for result in retried], ["duplicate"], "the slot was consumed once")
        self.hub.client("r1").pull()
        self.assertTrue(next(item for item in self.hub.client("r1").episodes()
                             if item["episode_id"] == episode["episode_id"])["in_queue"])
        session = next(iter(self.hub.client("r1").sessions))
        self.post("/r/r1/end", {"session": session, "position_ms": 1000, "completed": True})
        self.post("/r/r1/pull")
        self.assertFalse(next(item for item in self.hub.client("r1").episodes()
                              if item["episode_id"] == episode["episode_id"])["in_queue"])

    def test_crash_after_on_the_servers_live_event_stream_kills_at_its_first_event(self) -> None:
        account = self.post("/accounts", {"password": PASSWORD}, 201)
        self.post("/r/r2/login", {"username": account["username"], "password": PASSWORD})
        token = self.hub.client("r2").token
        rule = self.post("/proxy/rules", {"mode": "crash_after", "method": "GET", "path": "/v1/events"})
        mark = self.hub.events.last
        request = get("/v1/events", headers={"Authorization": f"Bearer {token}", "NotTennaPod-Protocol": "1"})
        outcome, data = raw(self.hub.proxy.port, request.replace(b"Connection: close\r\n", b""), timeout=30)
        self.assertEqual(data, b"", "nothing of the stream is relayed")
        killed = self.hub.events.select(mark, {"kind": "request", "rule": rule["rule"], "outcome": "server_killed"})
        self.assertEqual(killed[0]["boundary"], "first event")
        self.assertTrue(self.hub.events.select(mark, {"source": "server", "kind": "crashed"}))
        self.hub.server.await_restart()
        self.assertEqual(self.public("/v1/info")[0], "answer")

    def test_the_web_actor_speaks_protocol_one_and_subscribes_to_the_private_feed(self) -> None:
        hello = self.post("/web/hello")
        self.assertEqual(hello["result"]["protocol"], 1)
        first_pid = self.hub.web.process.pid
        self.post("/web/stop")
        self.assertTrue(self.post("/web/hello")["ok"])
        self.assertNotEqual(self.hub.web.process.pid, first_pid, "public stop allows a fresh owned actor")
        account = self.post("/accounts", {"password": PASSWORD}, 201)
        self.assertEqual(self.post("/web/w1/open")["result"]["state"], "sign_in")
        self.assertTrue(self.post("/web/w1/log_in", {"username": account["username"], "password": PASSWORD})["ok"])
        private = self.hub.publisher.describe()["feeds"]["private"]["url"]
        answer = self.post("/web/w1/subscribe", {"feed_url": private, "username": "listener", "password": "private-secret-1"})
        self.assertTrue(answer["ok"], answer)
        self.assertEqual(answer["result"]["title"], "Hub Private")
        fetched = self.hub.events.select(0, {"source": "publisher", "path": "/feeds/private.xml", "agent": "server", "status": 200})
        self.assertTrue(fetched, "the server fetched the private feed with the login")
        self.post("/web/w1/delete_profile")


if __name__ == "__main__":
    unittest.main()
