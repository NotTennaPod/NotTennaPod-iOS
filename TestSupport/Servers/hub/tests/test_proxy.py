"""The fault proxy's modes, each against a scripted upstream: what the client sees, what reaches the server, and
the events journeys wait on."""

from __future__ import annotations

import json
import socket
import threading
import time
import unittest
from unittest.mock import patch

from hub.events import EventLog
from hub.proxy import Answer, FaultProxy, redact

from .support import SPLIT_EVENT, FakeUpstream, framed, get, raw

PUSH = json.dumps({"operations": [{"install_seq": 1, "fact": {"op_id": "a", "type": "favorite.set", "payload": {}}}]}).encode()


class ProxyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.events = EventLog()
        self.upstream = FakeUpstream()
        self.up = True
        self.crashes: list[tuple[str, bool]] = []
        self.hangs: list[str] = []
        self.proxy = FaultProxy(self.events, 0, upstream=lambda: self.upstream.port if self.up else None,
                                crash=self.crash, hang=self.hangs.append)
        self.proxy.server_changed(True)
        self.proxy.start()

    def tearDown(self) -> None:
        self.proxy.stop()
        self.upstream.stop()

    def crash(self, reason: str, restart: bool) -> None:
        self.crashes.append((reason, restart))

    def send(self, request: bytes, timeout: float = 5.0) -> tuple[str, bytes]:
        return raw(self.proxy.port, request, timeout)

    def in_background(self, request: bytes, timeout: float = 10.0) -> tuple[threading.Thread, dict]:
        result: dict = {}
        thread = threading.Thread(target=lambda: result.update(answer=self.send(request, timeout)), daemon=True)
        thread.start()
        return thread, result

    # ---- passing through

    def test_inflight_state_decision_cannot_reopen_listener_after_stop(self):
        self.proxy.set_state("refuse")
        decided, release, stopping = threading.Event(), threading.Event(), threading.Event()
        original = self.proxy._open_listener

        def paused_open():
            decided.set()
            if not release.wait(5):
                raise TimeoutError("test listener barrier was not released")
            original()

        def stop():
            stopping.set()
            self.proxy.stop()

        with patch.object(self.proxy, "_open_listener", side_effect=paused_open):
            changing = threading.Thread(target=self.proxy.set_state, args=("pass",))
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
        self.assertIsNone(self.proxy.listener)
        self.assertIsNone(self.proxy.accepting)
        self.assertFalse(any(worker.is_alive() for worker in self.proxy.workers))
        original()  # A stale pre-stop decision cannot publish a listener after the final snapshot.
        self.assertIsNone(self.proxy.listener)

    def test_passes_requests_on_one_kept_connection_and_relays_chunked_bodies(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.proxy.port), timeout=5)
        reader = sock.makefile("rb")
        for _ in range(2):
            sock.sendall(b"GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            self.assertEqual(reader.readline(), b"HTTP/1.1 200 OK\r\n")
            length = 0
            while (line := reader.readline()) != b"\r\n":
                if line.lower().startswith(b"content-length"):
                    length = int(line.split(b":")[1])
            self.assertIn(b'"path": "/ok"', reader.read(length))
        sock.close()
        self.assertEqual(self.upstream.count("/ok"), 2)
        outcome, data = self.send(get("/chunked"))
        self.assertEqual(outcome, "answer")
        self.assertIn(b"4\r\none,\r\n4\r\ntwo,\r\n5\r\nthree\r\n0\r\n\r\n", data)

    def test_logs_each_request_without_its_query_and_redacts_media_tokens(self) -> None:
        self.send(get("/ok?token=secret"))
        logged = self.events.wait(0, {"kind": "request", "path": "/ok"})
        self.assertEqual(logged[0]["status"], 200)
        self.assertNotIn("secret", json.dumps(self.events.select()))
        self.assertEqual(redact("/v1/media/s/abcdef123/status"), "/v1/media/s/[token]/status")

    # ---- answers made up by the proxy

    def test_busy_answers_as_the_server_does_without_forwarding(self) -> None:
        self.proxy.arm({"mode": "busy", "path": "/ok", "retry_after": 7})
        outcome, data = self.send(get("/ok"))
        self.assertTrue(data.startswith(b"HTTP/1.1 503 Service Unavailable"), data)
        self.assertIn(b"Retry-After: 7", data)
        self.assertIn(b'"error": "server_busy"', data)
        self.assertIn(b'"retry_after": 7', data)
        self.assertEqual(self.upstream.count("/ok"), 0)

    def test_captive_and_status_answers(self) -> None:
        self.proxy.arm({"mode": "captive", "path": "/ok"})
        self.proxy.arm({"mode": "status", "path": "/chunked", "status": 401, "body": {"error": "unauthorized"}})
        self.assertIn(b"text/html", self.send(get("/ok"))[1])
        self.assertTrue(self.send(get("/chunked"))[1].startswith(b"HTTP/1.1 401 Unauthorized"))
        self.assertEqual(len(self.upstream.requests), 0)

    def test_a_rule_skips_then_fires_for_its_count_then_passes(self) -> None:
        rule = self.proxy.arm({"mode": "busy", "method": "GET", "path": "/ok", "skip": 1, "count": 2})
        statuses = [self.send(get("/ok"))[1].split(b" ")[1] for _ in range(4)]
        self.assertEqual(statuses, [b"200", b"503", b"503", b"200"])
        faults = self.events.select(0, {"kind": "fault", "rule": rule["rule"]})
        self.assertEqual(len(faults), 2)
        self.assertEqual(self.proxy.describe()["rules"][0]["state"], "done")

    def test_path_patterns_methods_and_fact_types_choose_the_request(self) -> None:
        self.proxy.arm({"mode": "busy", "method": "POST", "path": "/v1/*", "fact_type": "favorite.set"})
        self.assertIn(b" 200 ", self.send(get("/v1/push", "POST", b"{}"))[1])
        self.assertIn(b" 200 ", self.send(get("/v1/push"))[1])
        self.assertIn(b" 503 ", self.send(get("/v1/push", "POST", PUSH))[1])
        fault = self.events.select(0, {"kind": "fault"})[0]
        self.assertEqual(fault["facts"], ["favorite.set"])
        self.proxy.arm({"mode": "busy", "path": "/a/**"})
        self.assertIn(b" 503 ", self.send(get("/a/b/c/d"))[1])

    # ---- lost requests and answers

    def test_a_lost_request_never_reaches_the_server(self) -> None:
        self.proxy.arm({"mode": "drop_request", "path": "/v1/push"})
        outcome, data = self.send(get("/v1/push", "POST", PUSH))
        self.assertIn(outcome, ("reset", "closed"))
        self.assertEqual(data, b"")
        self.assertEqual(self.upstream.count("/v1/push"), 0)

    def test_a_lost_answer_reached_the_server(self) -> None:
        self.proxy.arm({"mode": "drop_answer", "path": "/v1/push"})
        outcome, data = self.send(get("/v1/push", "POST", PUSH))
        self.assertIn(outcome, ("reset", "closed"))
        self.assertEqual(data, b"")
        self.assertEqual(self.upstream.count("/v1/push"), 1)
        self.assertEqual(self.events.select(0, {"kind": "request", "outcome": "answer_dropped"})[0]["server_status"], 200)

    def test_a_duplicate_request_is_forwarded_twice(self) -> None:
        self.proxy.arm({"mode": "duplicate", "path": "/v1/push"})
        outcome, data = self.send(get("/v1/push", "POST", PUSH))
        self.assertEqual(outcome, "answer")
        self.assertIn(b"favorite.set", data)
        self.assertEqual(self.upstream.count("/v1/push"), 2)

    def test_a_stalled_answer_stops_mid_body_until_released(self) -> None:
        rule = self.proxy.arm({"mode": "stall", "path": "/big"})
        thread, result = self.in_background(get("/big"), timeout=30)
        stalled = self.events.wait(0, {"kind": "request", "outcome": "stalled"}, timeout=10)
        self.assertEqual(stalled[0]["relayed_bytes"], 5000)
        self.assertTrue(thread.is_alive())
        self.proxy.release_rule(rule["rule"])
        thread.join(10)
        outcome, data = result["answer"]
        self.assertIn(outcome, ("reset", "closed", "answer"))
        self.assertEqual(data.count(b"x"), 5000)

    def test_a_stall_always_stops_before_the_answer_is_complete(self) -> None:
        # A short answer: half of it, then nothing.
        self.proxy.arm({"mode": "stall", "path": "/ok"})
        outcome, data = self.send(get("/ok"), timeout=1.0)
        head, _, body = data.partition(b"\r\n\r\n")
        length = int(next(line for line in head.split(b"\r\n") if line.lower().startswith(b"content-length")).split(b":")[1])
        self.assertEqual((outcome, len(body)), ("silent", length // 2))
        # A chunked answer: never its last chunk.
        self.proxy.arm({"mode": "stall", "path": "/chunked"})
        outcome, data = self.send(get("/chunked"), timeout=1.0)
        self.assertEqual(outcome, "silent")
        self.assertFalse(data.endswith(b"0\r\n\r\n"), data)
        self.assertEqual(len(self.events.select(0, {"kind": "request", "outcome": "stalled"})), 2)

    def test_a_stall_that_cannot_happen_fails_explicitly_and_never_reports_a_stall(self) -> None:
        for path, cut in (("/big", 10000), ("/big", 20000), ("/chunked", 37), ("/empty", None)):
            mark = self.events.last
            rule = self.proxy.arm({"mode": "stall", "path": path, **({"after_bytes": cut} if cut is not None else {})})
            outcome, data = self.send(get(path), timeout=5)
            self.assertEqual(outcome, "answer", path)
            self.assertFalse(self.events.select(mark, {"kind": "request", "outcome": "stalled"}), f"{path} {cut}")
            failed = self.events.select(mark, {"kind": "fault_failed", "rule": rule["rule"]})
            self.assertEqual(len(failed), 1, f"{path} {cut}")
            self.assertEqual(next(r for r in self.proxy.describe()["rules"] if r["rule"] == rule["rule"])["state"], "failed")

    def test_a_silent_rule_answers_nothing_until_disarmed(self) -> None:
        rule = self.proxy.arm({"mode": "silent", "path": "/ok"})
        thread, result = self.in_background(get("/ok"), timeout=30)
        self.events.wait(0, {"kind": "request", "outcome": "silent"}, timeout=10)
        self.assertTrue(thread.is_alive())
        self.proxy.disarm(rule["rule"])
        thread.join(10)
        self.assertEqual(result["answer"][1], b"")
        self.assertEqual(self.upstream.count("/ok"), 0)

    # ---- holds

    def test_a_held_request_waits_for_its_release(self) -> None:
        self.proxy.arm({"mode": "hold", "method": "POST", "path": "/v1/push"})
        thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=30)
        held = self.events.wait(0, {"kind": "held"}, timeout=10)[0]
        self.assertEqual(held["facts"], ["favorite.set"])
        self.assertEqual(self.upstream.count("/v1/push"), 0)
        self.proxy.release(held["hold"], "continue")
        thread.join(10)
        self.assertEqual(result["answer"][0], "answer")
        self.assertEqual(self.upstream.count("/v1/push"), 1)

    def test_a_held_request_can_be_lost_or_lose_its_answer(self) -> None:
        self.proxy.arm({"mode": "hold", "path": "/v1/push", "count": 2})
        for mode, reached in (("drop_request", 0), ("drop_answer", 1)):
            thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=30)
            held = self.events.wait(0, {"kind": "held"}, count=1 + reached, timeout=10)[-1]
            self.proxy.release(held["hold"], mode)
            thread.join(10)
            self.assertEqual(result["answer"][1], b"", mode)
            self.assertEqual(self.upstream.count("/v1/push"), reached, mode)

    # ---- the server's process

    def test_crash_before_kills_before_forwarding_and_crash_after_once_answered(self) -> None:
        self.proxy.arm({"mode": "crash_before", "path": "/v1/push"})
        outcome, data = self.send(get("/v1/push", "POST", PUSH))
        self.assertEqual(data, b"")
        self.assertEqual(self.upstream.count("/v1/push"), 0)
        self.proxy.arm({"mode": "crash_after", "path": "/v1/push", "restart": False})
        outcome, data = self.send(get("/v1/push", "POST", PUSH))
        self.assertEqual(data, b"")
        self.assertEqual(self.upstream.count("/v1/push"), 1)
        self.assertEqual([restart for _, restart in self.crashes], [True, False])
        self.assertIn("before POST /v1/push", self.crashes[0][0])
        self.assertIn("after POST /v1/push answered 200", self.crashes[1][0])

    def test_on_a_live_event_stream_the_answer_is_its_first_event(self) -> None:
        """The server keeps /v1/events open, so "after S answered" is the stream's head and first event: the kill (or
        the lost answer) happens then, before anything is relayed, while the server's stream is still open."""
        stream = get("/v1/events").replace(b"Connection: close\r\n", b"")
        for mode in ("crash_after", "drop_answer"):
            self.upstream.stream_open.clear()
            mark = self.events.last
            self.proxy.arm({"mode": mode, "path": "/v1/events", "restart": False})
            thread, result = self.in_background(stream, timeout=10)
            done = self.events.wait(mark, {"kind": "request", "path": "/v1/events",
                                           "outcome": ["server_killed", "answer_dropped"]}, timeout=5)
            self.assertIsNotNone(done, f"{mode} happens while the stream is open")
            self.assertEqual(done[0]["boundary"], "first event")
            self.assertTrue(self.upstream.stream_open.wait(5), "the server opened its stream")
            self.assertFalse(self.upstream.release_stream.is_set(), "the server's stream is still open")
            thread.join(10)
            self.assertEqual(result["answer"][1], b"", f"{mode}: nothing of the stream is relayed")
        self.assertEqual(len(self.crashes), 1)
        # A stalled stream relays its head and first event, then nothing.
        self.proxy.arm({"mode": "stall", "path": "/v1/events"})
        outcome, data = self.send(stream, timeout=1.0)
        self.assertEqual(outcome, "silent")
        self.assertEqual(data.count(b"event: changed"), 1)

    def test_an_event_streams_first_event_is_a_complete_event_and_its_end_is_not_an_event(self) -> None:
        def answer(raw_bytes: bytes) -> Answer:
            near, far = socket.socketpair()
            self.addCleanup(near.close)
            far.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" + raw_bytes)
            self.addCleanup(far.close)
            return Answer(near, "GET")
        split = framed(SPLIT_EVENT)
        self.assertEqual(answer(split + framed([b"event: changed\n\n"])).first_event(), split, "the event split over two chunks")
        crlf = framed([b"event: changed\r\ndata: {}\r", b"\n\r\n"])
        self.assertEqual(answer(crlf).first_event(), crlf)
        ended = answer(b"0\r\n\r\n")
        self.assertIsNone(ended.first_event(), "the last chunk is not an event")
        self.assertEqual(ended.read, b"0\r\n\r\n")

    def test_finite_and_ended_event_streams_never_stall_or_kill_at_a_first_event(self) -> None:
        # A stream that ends at once: a stall cannot happen, and the server answered when the stream ended.
        mark = self.events.last
        rule = self.proxy.arm({"mode": "stall", "path": "/sse-empty"})
        outcome, data = self.send(get("/sse-empty"), timeout=5)
        self.assertEqual(outcome, "answer")
        self.assertTrue(data.endswith(b"0\r\n\r\n"))
        self.assertFalse(self.events.select(mark, {"outcome": "stalled"}))
        self.assertEqual(len(self.events.select(mark, {"kind": "fault_failed", "rule": rule["rule"]})), 1)
        self.proxy.arm({"mode": "crash_after", "path": "/sse-empty", "restart": False})
        self.send(get("/sse-empty"), timeout=5)
        self.assertEqual(self.events.select(mark, {"outcome": "server_killed"})[-1]["boundary"], "stream ended")
        # A stream framed by its length is a finite answer: stalled mid-body, killed after all of it.
        mark = self.events.last
        self.proxy.arm({"mode": "stall", "path": "/sse-length"})
        outcome, data = self.send(get("/sse-length"), timeout=1.0)
        self.assertEqual(outcome, "silent")
        stalled = self.events.select(mark, {"outcome": "stalled"})[0]
        self.assertEqual((stalled["relayed_bytes"], stalled["body_bytes"]), (12, 25))
        self.proxy.arm({"mode": "crash_after", "path": "/sse-length", "restart": False})
        self.send(get("/sse-length"), timeout=5)
        self.assertEqual(self.events.select(mark, {"outcome": "server_killed"})[-1]["boundary"], "whole answer")

    def test_a_kill_after_a_streams_first_event_waits_for_the_whole_event(self) -> None:
        mark = self.events.last
        self.proxy.arm({"mode": "crash_after", "path": "/sse-split", "restart": False})
        thread, result = self.in_background(get("/sse-split").replace(b"Connection: close\r\n", b""), timeout=10)
        killed = self.events.wait(mark, {"kind": "request", "outcome": "server_killed"}, timeout=5)
        self.assertIsNotNone(killed)
        self.assertEqual(killed[0]["boundary"], "first event")
        self.assertEqual(killed[0]["read_bytes"], len(framed(SPLIT_EVENT)), "both chunks of the event were read")
        self.assertFalse(self.upstream.release_stream.is_set())
        thread.join(10)
        self.assertEqual(result["answer"][1], b"")

    def test_hang_before_stops_the_server_and_forwards(self) -> None:
        self.proxy.arm({"mode": "hang_before", "path": "/ok"})
        self.assertEqual(self.send(get("/ok"))[0], "answer")
        self.assertEqual(len(self.hangs), 1)

    # ---- connections

    def test_refuse_and_a_stopped_server_refuse_connections(self) -> None:
        self.proxy.set_state("refuse")
        self.assertEqual(self.send(get("/ok"))[0], "refused")
        self.proxy.set_state("pass")
        self.assertEqual(self.send(get("/ok"))[0], "answer")
        self.up = False
        self.proxy.server_changed(False)
        self.assertEqual(self.send(get("/ok"))[0], "refused")
        self.up = True
        self.proxy.server_changed(True)
        self.assertEqual(self.send(get("/ok"))[0], "answer")

    def test_silent_accepts_and_never_answers(self) -> None:
        self.proxy.set_state("silent")
        self.assertEqual(self.send(get("/ok"), timeout=1.0), ("silent", b""))
        self.proxy.set_state("pass")
        self.assertEqual(self.send(get("/ok"))[0], "answer")
        self.assertEqual(self.upstream.count("/ok"), 1)

    # ---- connections opened before a change of state

    def kept(self) -> socket.socket:
        """A connection that already had an answer and is kept for the next request, as a client's pool keeps it."""
        sock = socket.create_connection(("127.0.0.1", self.proxy.port), timeout=5)
        sock.sendall(b"GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        received = b""
        while not received.endswith(b"}"):
            received += sock.recv(4096)
        return sock

    def streaming(self) -> socket.socket:
        """An event stream that already relayed its first event."""
        self.upstream.stream_open.clear()
        sock = socket.create_connection(("127.0.0.1", self.proxy.port), timeout=5)
        sock.sendall(b"GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        received = b""
        while b"event: changed" not in received:
            received += sock.recv(4096)
        return sock

    @staticmethod
    def again(sock: socket.socket, timeout: float) -> tuple[str, bytes]:
        sock.settimeout(timeout)
        received = b""
        try:
            sock.sendall(b"GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            while not received.endswith(b"}"):
                data = sock.recv(4096)
                if not data:
                    return "closed", received
                received += data
            return "answered", received
        except (ConnectionResetError, BrokenPipeError):
            return "closed", received
        except socket.timeout:
            return "silent", received

    @staticmethod
    def ended(sock: socket.socket, timeout: float) -> str:
        """What an open connection meets next: its end, more data, or nothing."""
        sock.settimeout(timeout)
        try:
            return "data" if sock.recv(4096) else "closed"
        except ConnectionResetError:
            return "closed"
        except socket.timeout:
            return "silent"

    def until(self, condition, what: str, limit: float = 10) -> None:
        deadline = time.monotonic() + limit
        while not condition():
            self.assertLess(time.monotonic(), deadline, what)
            time.sleep(0.02)

    def test_refuse_closes_every_connection_already_open(self) -> None:
        kept = self.kept()
        stream = self.streaming()
        self.proxy.arm({"mode": "hold", "method": "POST", "path": "/v1/push"})
        thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=10)
        self.events.wait(0, {"kind": "held"}, timeout=5)
        before = self.upstream.count("/ok")
        self.proxy.set_state("refuse")
        self.assertEqual(self.again(kept, 5), ("closed", b""), "a kept connection is closed, its request never sent")
        self.assertEqual(self.upstream.count("/ok"), before)
        self.assertEqual(self.ended(stream, 5), "closed", "an open event stream ends at once")
        thread.join(10)
        self.assertEqual(result["answer"][1], b"")
        self.assertEqual(self.upstream.count("/v1/push"), 0, "a held request is never forwarded")
        self.assertEqual(self.send(get("/ok"))[0], "refused")
        self.until(lambda: not self.proxy.clients and not self.proxy.relays,
                   f"every connection is gone: {list(self.proxy.clients.values())}, {len(self.proxy.relays)} relays")

    def test_silent_holds_kept_connections_and_streams_and_lets_go_of_clients_that_leave(self) -> None:
        kept = self.kept()
        stream = self.streaming()
        leaving = [self.kept() for _ in range(4)]
        self.proxy.set_state("silent")
        self.assertEqual(self.again(kept, 0.5), ("silent", b""), "a kept connection's request gets no answer")
        for sock in leaving:
            sock.sendall(b"GET /ok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        # Held: the kept connection's request, the four others, and the stream (silence ended its wait on the server).
        self.until(lambda: sum(1 for state in self.proxy.clients.values() if state == "parked") == 6, "requests held")
        for sock in leaving:
            sock.close()
        self.until(lambda: len(self.proxy.clients) == 2,
                   f"the connections of clients that left are let go: {list(self.proxy.clients.values())}")
        self.upstream.release_stream.set()  # the server sends another event and ends the stream
        self.assertEqual(self.ended(stream, 0.5), "silent", "nothing more of the stream is relayed while silent")
        self.proxy.set_state("pass")
        self.assertEqual(self.ended(kept, 5), "closed")
        self.assertEqual(self.ended(stream, 5), "closed")
        self.assertEqual(self.send(get("/ok"))[0], "answer")

    # ---- forwarding against a change of state

    def barrier(self) -> tuple[threading.Event, threading.Event]:
        """Stops each request after its body is read and before the proxy handles it, until `go` is set."""
        reached, go = threading.Event(), threading.Event()
        self.proxy.after_body = lambda: (reached.set(), go.wait(10))
        return reached, go

    def test_a_request_read_before_refusal_never_reaches_the_server(self) -> None:
        reached, go = self.barrier()
        thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=10)
        self.assertTrue(reached.wait(5))
        self.proxy.set_state("refuse")
        go.set()
        thread.join(10)
        self.assertEqual(result["answer"][1], b"")
        # The client was cut at once; what counts is what the handler does after it: wait for it to finish.
        self.until(lambda: not self.proxy.clients, "the handler is gone")
        self.assertEqual(self.upstream.count("/v1/push"), 0, "refusal won: the request was never forwarded")
        self.assertFalse(self.proxy.relays)

    def test_a_request_read_before_silence_is_never_forwarded_or_answered(self) -> None:
        reached, go = self.barrier()
        thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=1.0)
        self.assertTrue(reached.wait(5))
        self.proxy.set_state("silent")
        go.set()
        thread.join(10)
        self.assertEqual(result["answer"], ("silent", b""), "no answer while silent")
        self.until(lambda: all(state == "parked" for state in self.proxy.clients.values()), "the request is held")
        self.assertEqual(self.upstream.count("/v1/push"), 0)

    def test_a_held_request_released_during_silence_is_never_forwarded(self) -> None:
        self.proxy.arm({"mode": "hold", "method": "POST", "path": "/v1/push"})
        thread, result = self.in_background(get("/v1/push", "POST", PUSH), timeout=1.0)
        held = self.events.wait(0, {"kind": "held"}, timeout=5)[0]
        self.proxy.set_state("silent")
        self.proxy.release(held["hold"], "continue")
        thread.join(10)
        self.assertEqual(result["answer"], ("silent", b""))
        self.assertEqual(self.upstream.count("/v1/push"), 0)

    def test_an_answer_that_comes_during_silence_is_never_relayed(self) -> None:
        # Forwarded before the silence; the server answers (here: ends its withheld answer) during it.
        thread, result = self.in_background(get("/withhold"), timeout=1.0)
        self.assertTrue(self.upstream.withheld.wait(5))
        self.proxy.set_state("silent")
        self.upstream.release_stream.set()
        thread.join(10)
        self.assertEqual(result["answer"], ("silent", b""), "nothing of the answer while silent")

    def test_refusal_ends_a_relay_waiting_for_the_servers_answer(self) -> None:
        thread, result = self.in_background(get("/withhold"), timeout=10)
        self.assertTrue(self.upstream.withheld.wait(5))
        self.assertEqual(len(self.proxy.relays), 1, "the relay is known while it waits for the answer")
        self.proxy.set_state("refuse")
        thread.join(10)
        self.assertEqual(result["answer"][1], b"")
        self.until(lambda: not self.proxy.clients and not self.proxy.relays,
                   f"the handler and its server connection end: {list(self.proxy.clients.values())}")
        self.assertFalse(self.upstream.release_stream.is_set(), "without the server answering")

    def test_a_duplicates_first_relay_is_ended_by_refusal(self) -> None:
        self.proxy.arm({"mode": "duplicate", "path": "/withhold"})
        thread, result = self.in_background(get("/withhold"), timeout=10)
        self.assertTrue(self.upstream.withheld.wait(5))
        self.proxy.set_state("refuse")
        thread.join(10)
        self.until(lambda: not self.proxy.clients and not self.proxy.relays, "the duplicate's handler ends")
        self.assertEqual(self.upstream.count("/withhold"), 1, "the second copy is never sent")

    def test_a_client_leaving_a_quiet_silenced_or_dead_stream_is_let_go(self) -> None:
        for freeze, thaw in ((lambda: self.proxy.set_state("silent"), lambda: self.proxy.set_state("pass")),
                             (lambda: self.proxy.set_dead_events(True), lambda: self.proxy.set_dead_events(False))):
            stream = self.streaming()  # the server sends nothing more and keeps its stream open
            freeze()
            stream.close()
            self.until(lambda: not self.proxy.clients and not self.proxy.relays,
                       f"the handler and its server connection end: {list(self.proxy.clients.values())}")
            self.assertFalse(self.upstream.release_stream.is_set(), "the server's stream was never released")
            thaw()

    def test_a_dead_event_stream_stays_open_and_silent_also_when_the_server_ends_it(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.proxy.port), timeout=10)
        sock.sendall(get("/v1/events").replace(b"Connection: close\r\n", b""))
        received = b""
        while b"event: changed" not in received:
            received += sock.recv(4096)
        self.proxy.set_dead_events(True)
        self.upstream.release_stream.set()  # the server sends another event and ends the stream (a restart)
        self.events.wait(0, {"kind": "request", "path": "/v1/events", "outcome": "dead_events"}, timeout=10)
        sock.settimeout(0.5)
        with self.assertRaises(socket.timeout):
            sock.recv(4096)
        self.assertEqual(self.send(get("/v1/events"), timeout=0.5), ("silent", b""))
        self.proxy.set_dead_events(False)
        sock.settimeout(10)
        try:
            self.assertEqual(sock.recv(4096), b"")
        except ConnectionResetError:
            pass
        sock.close()


if __name__ == "__main__":
    unittest.main()
