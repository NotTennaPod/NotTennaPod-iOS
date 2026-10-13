"""The publisher: its feeds, the private feed's only accepted login, media told apart by duration with strong ETags
and ranges, the mutations, the faults and the counts."""

from __future__ import annotations

import base64
import socket
import threading
import time
import unittest
import xml.etree.ElementTree as ElementTree
from unittest.mock import patch

from hub.events import EventLog
from hub.publisher import Publisher, mp3_frames, repeated_mp3, ROOT

from .support import get, raw

SERVER = "NotTennaPod-Server"
APP = "NotTennaPod/3.12.1"


def basic(username: str, password: str) -> str:
    return "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events = EventLog()
        self.publisher = Publisher(self.events, 0)
        self.publisher.start()

    def tearDown(self) -> None:
        self.publisher.stop()

    def fetch(self, path: str, method: str = "GET", agent: str = APP, **headers) -> tuple[int, dict, bytes]:
        outcome, data = raw(self.publisher.port, get(path, method, headers={"User-Agent": agent, **headers}))
        self.assertEqual(outcome, "answer", path)
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        fields = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip() for line in lines[1:]}
        return int(lines[0].split(" ")[1]), fields, body

    def items(self, body: bytes) -> list[dict]:
        channel = ElementTree.fromstring(body).find("channel")
        return [{"guid": item.findtext("guid"), "title": item.findtext("title"),
                 "url": item.find("enclosure").get("url") if item.find("enclosure") is not None else None}
                for item in channel.findall("item")]

    def test_repeated_media_have_their_own_durations_and_bytes(self) -> None:
        source = (ROOT / "TestSupport/Media/listening/sync-60sec.mp3").read_bytes()
        frames = mp3_frames(source)
        self.assertGreater(len(frames), 500)
        once = repeated_mp3(source, 1)
        self.assertEqual(len(repeated_mp3(source, 3)), 3 * len(once))
        media = self.publisher.describe()["media"]
        self.assertEqual(len({value["etag"] for value in media.values()}), len(media))
        self.assertEqual(sorted(value["seconds"] for value in media.values()), [8, 20, 30, 60, 120, 180, 300])

    def test_inflight_refuse_to_pass_cannot_reopen_after_terminal_stop(self):
        self.publisher.set_state("refuse")
        decided, release, stopping = threading.Event(), threading.Event(), threading.Event()
        original = self.publisher._listen
        errors = []

        def paused_listen():
            decided.set()
            if not release.wait(5):
                raise TimeoutError("test listener barrier was not released")
            original()

        def change():
            try:
                self.publisher.set_state("pass")
            except Exception as error:
                errors.append(error)

        def stop():
            stopping.set()
            self.publisher.stop()

        with patch.object(self.publisher, "_listen", side_effect=paused_listen):
            changing = threading.Thread(target=change)
            changing.start()
            self.assertTrue(decided.wait(5))
            shutdown = threading.Thread(target=stop)
            shutdown.start()
            self.assertTrue(stopping.wait(5))
            release.set()
            changing.join(5)
            shutdown.join(5)
        self.assertFalse(changing.is_alive())
        self.assertFalse(shutdown.is_alive())
        self.assertEqual(errors, [])
        self.assertIsNone(self.publisher.server)
        self.assertFalse(self.publisher.thread.is_alive())
        original()  # A queued stale creation is refused after terminal stop.
        self.assertIsNone(self.publisher.server)
        with self.assertRaisesRegex(RuntimeError, "shutting down"):
            self.publisher.set_state("pass")

    def test_a_feed_lists_its_items_newest_first_with_enclosures(self) -> None:
        status, headers, body = self.fetch("/feeds/daily.xml")
        self.assertEqual(status, 200)
        self.assertEqual([item["guid"] for item in self.items(body)], ["hub-daily-3", "hub-daily-2", "hub-daily-1"])
        status, _, _ = self.fetch("/feeds/daily.xml", **{"If-None-Match": headers["etag"]})
        self.assertEqual(status, 304)
        self.assertEqual(len(self.items(self.fetch("/feeds/backlog.xml")[2])), 200)

    def test_media_have_strong_etags_and_ranges(self) -> None:
        url = self.items(self.fetch("/feeds/daily.xml")[2])[0]["url"].split(str(self.publisher.port), 1)[1]
        status, headers, body = self.fetch(url)
        self.assertEqual((status, headers["accept-ranges"]), (200, "bytes"))
        self.assertFalse(headers["etag"].startswith("W/"))
        size = len(body)
        status, headers, part = self.fetch(url, Range="bytes=100-199")
        self.assertEqual((status, headers["content-range"], part), (206, f"bytes 100-199/{size}", body[100:200]))
        self.assertEqual(self.fetch(url, Range="bytes=-10")[2], body[-10:])
        self.assertEqual(self.fetch(url, Range="bytes=0-9", **{"If-Range": '"other"'})[0], 200)
        self.assertEqual(self.fetch(url, Range=f"bytes={size + 5}-")[0], 416)
        status, headers, empty = self.fetch(url, "HEAD")
        self.assertEqual((status, headers["content-length"], empty), (200, str(size), b""))

    def test_the_private_feed_accepts_only_the_current_login_for_feed_and_media(self) -> None:
        self.assertEqual(self.fetch("/feeds/private.xml")[0], 401)
        status, _, body = self.fetch("/feeds/private.xml", Authorization=basic("listener", "private-secret-1"))
        self.assertEqual(status, 200)
        media = self.items(body)[0]["url"].split(str(self.publisher.port), 1)[1]
        self.assertEqual(self.fetch(media)[0], 401)
        self.assertEqual(self.fetch(media, Authorization=basic("listener", "private-secret-1"))[0], 200)
        self.publisher.set_login("private", "listener", "private-secret-2")
        self.assertEqual(self.fetch("/feeds/private.xml", Authorization=basic("listener", "private-secret-1"))[0], 401)
        self.assertEqual(self.fetch("/feeds/private.xml", Authorization=basic("listener", "private-secret-2"))[0], 200)
        self.assertNotIn("private-secret", str(self.events.select()))

    def test_mutations(self) -> None:
        guids = lambda: [item["guid"] for item in self.items(self.fetch("/feeds/identity.xml")[2])]
        self.publisher.mutate("identity", {"op": "new_item", "title": "Three", "media": "tone-180"})
        self.assertEqual(guids()[0], "hub-identity-new-3")
        self.publisher.mutate("identity", {"op": "backfill", "title": "Old", "media": "tone-8"})
        self.assertEqual(guids()[-1], "hub-identity-old-4")
        self.publisher.mutate("identity", {"op": "remove_enclosure", "guid": "hub-identity-1"})
        self.assertIsNone(self.items(self.fetch("/feeds/identity.xml")[2])[-2]["url"])
        self.publisher.mutate("identity", {"op": "gain_enclosure", "guid": "hub-identity-1", "media": "tone-30"})
        self.assertIsNotNone(self.items(self.fetch("/feeds/identity.xml")[2])[-2]["url"])
        self.publisher.mutate("identity", {"op": "change_guids", "suffix": "-v2", "guids": ["hub-identity-2"]})
        self.assertIn("hub-identity-2-v2", guids())
        self.publisher.mutate("identity", {"op": "reuse_guid", "guid": "hub-identity-1", "title": "Reused", "media": "tone-120"})
        items = self.items(self.fetch("/feeds/identity.xml")[2])
        self.assertEqual([item["title"] for item in items if item["guid"] == "hub-identity-1"], ["Reused"])
        self.publisher.mutate("identity", {"op": "move"})
        status, headers, _ = self.fetch("/feeds/identity.xml")
        self.assertEqual((status, headers["location"]), (301, f"{self.publisher.base}/feeds/identity-moved-1.xml"))
        self.assertEqual(self.fetch("/feeds/identity-moved-1.xml")[0], 200)
        self.publisher.reset()
        self.assertEqual(guids(), ["hub-identity-2", "hub-identity-1"])

    def test_faults_media_off_user_agents_and_states(self) -> None:
        media = self.items(self.fetch("/feeds/daily.xml")[2])[0]["url"].split(str(self.publisher.port), 1)[1]
        self.publisher.set_media_off(True)
        self.assertEqual(self.fetch(media)[0], 404)
        self.publisher.set_media_off(False)
        self.publisher.refuse_agent(SERVER)
        self.assertEqual(self.fetch("/feeds/daily.xml", agent="NotTennaPod-Server/1 (+https://x)")[0], 403)
        self.assertEqual(self.fetch("/feeds/daily.xml")[0], 200)
        self.assertEqual(self.fetch(media, agent=SERVER)[0], 200)
        self.publisher.refuse_agent(None)
        self.publisher.set_state("refuse")
        self.assertEqual(raw(self.publisher.port, get("/feeds/daily.xml"))[0], "refused")
        self.publisher.set_state("silent")
        self.assertEqual(raw(self.publisher.port, get("/feeds/daily.xml"), timeout=0.5), ("silent", b""))
        self.publisher.set_state("pass")
        self.assertEqual(self.fetch("/feeds/daily.xml")[0], 200)

    def kept_connection(self) -> socket.socket:
        """An HTTP/1.1 connection that already fetched a feed, as a client's connection pool keeps it."""
        sock = socket.create_connection(("127.0.0.1", self.publisher.port), timeout=5)
        sock.sendall(b"GET /feeds/daily.xml HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        received = b""
        while b"</rss>" not in received:
            received += sock.recv(65536)
        return sock

    @staticmethod
    def again(sock: socket.socket, timeout: float) -> tuple[str, bytes]:
        """The same request again on that connection: what comes back, or silence."""
        sock.settimeout(timeout)
        received = b""
        try:
            sock.sendall(b"GET /feeds/daily.xml HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            while True:
                data = sock.recv(65536)
                if not data:
                    return "closed", received
                received += data
                if b"</rss>" in received:
                    return "answered", received
        except (ConnectionResetError, BrokenPipeError):
            return "closed", received
        except socket.timeout:
            return "silent", received

    def test_an_outage_reaches_connections_opened_before_it(self) -> None:
        silent = self.kept_connection()
        self.publisher.set_state("silent")
        self.assertEqual(self.again(silent, 0.5), ("silent", b""), "a kept connection gets no answer while silent")
        self.publisher.set_state("pass")
        self.assertEqual(self.again(silent, 5)[1], b"", "and nothing after the silence either")
        silent.close()
        refused = self.kept_connection()
        self.publisher.set_state("refuse")
        self.assertEqual(self.again(refused, 5), ("closed", b""), "a kept connection is closed when the publisher refuses")
        refused.close()
        self.publisher.set_state("pass")
        self.assertEqual(self.fetch("/feeds/daily.xml")[0], 200)

    def until(self, condition, what: str, limit: float = 10) -> None:
        deadline = time.monotonic() + limit
        while not condition():
            self.assertLess(time.monotonic(), deadline, what)
            time.sleep(0.02)

    def test_while_silent_a_client_that_goes_away_is_let_go_and_one_that_stays_waits(self) -> None:
        leaving = [self.kept_connection() for _ in range(6)]
        staying = self.kept_connection()
        accepted_silent = socket.create_connection(("127.0.0.1", self.publisher.port), timeout=5)
        self.publisher.set_state("silent")
        # Accepted during the silence: the publisher holds its connection too, also one whose request is never read.
        late = socket.create_connection(("127.0.0.1", self.publisher.port), timeout=5)
        late.sendall(b"GET /feeds/daily.xml HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        for sock in leaving + [staying]:
            sock.sendall(b"GET /feeds/daily.xml HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        self.until(lambda: len(self.publisher.connections) == 9, "every connection is held")
        for sock in leaving + [accepted_silent, late]:
            sock.close()
        self.until(lambda: len(self.publisher.connections) == 1, "the handlers of clients that went away finish")
        self.assertEqual(self.again(staying, 0.3), ("silent", b""), "the client that stays gets no answer")
        self.publisher.set_state("pass")
        staying.close()
        self.until(lambda: not self.publisher.connections, "the last handler finishes after the silence")

    def test_requests_are_counted_by_who_asked(self) -> None:
        media = self.items(self.fetch("/feeds/daily.xml")[2])[0]["url"].split(str(self.publisher.port), 1)[1]
        self.fetch(media)
        self.fetch(media, agent=SERVER)
        self.fetch(media, agent="AppleCoreMedia/1.0")
        counts = self.publisher.count_report()[media]
        self.assertEqual((counts["app"], counts["server"], counts["total"]), (2, 1, 3))
        self.assertEqual(len(self.events.select(0, {"source": "publisher", "kind": "request", "path": media})), 3)


if __name__ == "__main__":
    unittest.main()
