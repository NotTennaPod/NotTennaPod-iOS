"""The fault proxy (PROTOCOL §16): the port apps and browsers use (18830), with the server
behind it on a private port. Everything passes through unless a fault is set.

Connection faults, until changed (`state`):
  pass      everything is forwarded (the default)
  refuse    connections are refused at once (the listener is closed), and every open one is closed, kept, streaming
            or held (a held request is never forwarded), as when the server is stopped
  silent    connections are accepted and nothing is ever answered, as when the Mac sleeps or Tailscale is gone: every
            request meets it, on connections opened before it too, and open event streams relay nothing more; a
            client that goes away meanwhile is let go
A request is forwarded only while the proxy passes, checked under the same lock as a change of state, after its
body is read, after a hold is released and once more just before it is sent: one read before a refusal or silence
never reaches the server. Each relay is registered before it connects, so a refusal (or stop) also ends one still
connecting, sending or waiting for the server's answer, and silence (or a dead stream, for event streams) ends its
wait on the server and holds its client unanswered, watching for it to go away. Nothing the server answers is
relayed during a silence, not even a finite answer's head.
While the hub has no server running (stopped, crashed and not yet restarted), the proxy refuses, whatever `state`
says, as a stopped server's port does. A hung server (SIGSTOP) is reached: its kernel accepts and nothing answers.

The dead event stream (`dead_events`): `/v1/events` connections stay open and nothing more is forwarded on them, also
while the server restarts behind them; new ones are held unanswered. Turning it off closes them, as a waking client
finally notices.

Request faults are rules, each armed for a kind of request (`method`, `path`: `*` one segment, `**` any number;
`fact_type`: a push carrying a fact of that type), skipping the first `skip` matches ("the third push" is skip 2) and
firing on the next `count` (0: every one until disarmed). The first armed rule that takes a request decides it:
  drop_request   the connection is reset before anything is forwarded (a lost request)
  drop_answer    forwarded; the server answers; the connection is reset before the answer is relayed (a lost answer)
  duplicate      forwarded twice; the second answer is relayed
  stall          forwarded; the answer's head and `after_bytes` of its body as relayed (chunk framing included;
                 default half) are relayed, then nothing more until released; then the connection is reset (a pull
                 page stalls mid-body). A cut that would complete the answer, or an answer without a body, cannot
                 stall: the answer is relayed whole, `fault_failed` is logged and the rule's state is "failed"
  busy           answered `503 server_busy` with `retry_after` (default 2), as the server does
  captive        answered 200 with an HTML page (not this server)
  status         answered with `status` and the JSON `body` given
  silent         read and never answered until released; then reset
  hold           held before forwarding until released: `continue`, `drop_request` or `drop_answer`
  crash_before   the server is killed (SIGKILL) before the request is forwarded; the connection is reset
  crash_after    forwarded; once the server answered it is killed before the answer is relayed; reset. A finite
                 answer has answered when all of it arrived; a live event stream (/v1/events: 2xx
                 text/event-stream, chunked or until closed, kept open by the server) when its head and first
                 complete event (ended by a blank line, across chunks) arrived, so the kill happens while the
                 stream is open; a stream that ends first has answered when it ended. An event stream framed by its
                 length is a finite answer. drop_answer, duplicate and stall use the same boundary; a stream that
                 ends before its first event cannot stall (fault_failed)
  hang_before    the server is stopped (SIGSTOP) and the request forwarded to it, so it hangs there
After a crash the server restarts on the same data directory unless the rule says `"restart": false`.

Every request is logged when it ends (`request`: method, path without its query, status relayed, the rule and mode
that decided it); a rule firing logs `fault` at once, a held request `held`. Paths of media relay tokens are
redacted. Bodies are never logged.
"""

from __future__ import annotations

import itertools
from http import HTTPStatus
import json
import re
import select
import socket
import struct
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

MAX_HEAD = 64 * 1024
REQUEST_MODES = {"drop_request", "drop_answer", "duplicate", "stall", "busy", "captive", "status", "silent", "hold",
                 "crash_before", "crash_after", "hang_before"}
STATES = {"pass", "refuse", "silent"}
CAPTIVE = (b"<!DOCTYPE html><html><head><title>Sign in to the network</title></head>"
           b"<body><h1>Welcome</h1><p>Accept the terms to use this network.</p></body></html>")


class Closed(Exception):
    """The peer went away, or sent something that is not HTTP."""


def path_pattern(pattern: str) -> re.Pattern:
    parts = []
    for segment in pattern.strip("/").split("/"):
        parts.append(".*" if segment == "**" else "[^/]+" if segment == "*" else re.escape(segment))
    return re.compile("^/" + "/".join(parts) + "$")


def redact(path: str) -> str:
    """The logged form of a path: no query, no media relay token."""
    path = path.split("?", 1)[0]
    return re.sub(r"^/v1/media/s/[^/]+", "/v1/media/s/[token]", path)


def _phrase(status: int) -> str:
    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return "Status"


def cut(sock: socket.socket) -> None:
    """Ends a connection another thread is serving, at once: its reader sees the end, and the final close resets it.
    (Closing the socket object would wait for the serving thread's reader to close.)"""
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def gone(sock: socket.socket) -> bool:
    """Whether the client of a connection that will never be answered closed or reset it. What it sent meanwhile is
    read and dropped, so a close behind a request is seen too."""
    try:
        while select.select([sock], [], [], 0)[0]:
            if not sock.recv(65536):
                return True
        return False
    except (OSError, ValueError):
        return True


def reset(sock: socket.socket) -> None:
    """Closes with RST, as a dead peer or a dropped connection looks."""
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


# ---- HTTP/1.1 framing

def read_head(reader) -> list[bytes] | None:
    lines: list[bytes] = []
    total = 0
    while True:
        line = reader.readline(MAX_HEAD + 1)
        if not line:
            if lines:
                raise Closed("closed inside a head")
            return None
        total += len(line)
        if total > MAX_HEAD:
            raise Closed("head too large")
        if line in (b"\r\n", b"\n"):
            if lines:
                return lines
            continue
        lines.append(line)


class Head:
    def __init__(self, lines: list[bytes]) -> None:
        self.first = lines[0].decode("latin-1").rstrip("\r\n")
        self.headers: list[tuple[str, str]] = []
        for line in lines[1:]:
            name, _, value = line.decode("latin-1").partition(":")
            self.headers.append((name.strip(), value.strip()))

    def get(self, name: str) -> str | None:
        name = name.lower()
        for key, value in self.headers:
            if key.lower() == name:
                return value
        return None

    def without(self, *names: str) -> list[tuple[str, str]]:
        drop = {name.lower() for name in names}
        return [(key, value) for key, value in self.headers if key.lower() not in drop]

    @staticmethod
    def encode(first: str, headers: list[tuple[str, str]]) -> bytes:
        return (first + "\r\n" + "".join(f"{key}: {value}\r\n" for key, value in headers) + "\r\n").encode("latin-1")


def read_exact(reader, size: int) -> bytes:
    data = reader.read(size)
    if data is None or len(data) < size:
        raise Closed("closed inside a body")
    return data


def read_body(reader, head: Head) -> bytes:
    """A request body, decoded: chunked bodies are joined (and forwarded with a length)."""
    if "chunked" in (head.get("Transfer-Encoding") or "").lower():
        parts = []
        while True:
            size_line = reader.readline(1024)
            if not size_line:
                raise Closed("closed inside a chunk")
            size = int(size_line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while reader.readline(MAX_HEAD) not in (b"\r\n", b"\n", b""):
                    pass
                return b"".join(parts)
            parts.append(read_exact(reader, size))
            reader.readline(4)
    length = head.get("Content-Length")
    return read_exact(reader, int(length)) if length else b""


class Answer:
    """The server's answer on an upstream connection: its head, then its body as it arrives, framing kept."""

    def __init__(self, sock: socket.socket, method: str) -> None:
        self.sock = sock
        self.reader = sock.makefile("rb")
        lines = read_head(self.reader)
        if lines is None:
            raise Closed("the server closed without answering")
        self.head = Head(lines)
        parts = self.head.first.split(" ", 2)
        self.status = int(parts[1])
        self.chunked = "chunked" in (self.head.get("Transfer-Encoding") or "").lower()
        length = self.head.get("Content-Length")
        self.length = int(length) if length is not None and not self.chunked else None
        self.empty = method == "HEAD" or self.status in (204, 304) or 100 <= self.status < 200
        self.until_close = not self.empty and not self.chunked and self.length is None
        self.streaming = (self.head.get("Content-Type") or "").startswith("text/event-stream")
        self.read = b""

    def client_head(self, keep_alive: bool) -> bytes:
        headers = self.head.without("Connection", "Keep-Alive")
        if not keep_alive or self.until_close:
            headers.append(("Connection", "close"))
        return Head.encode(self.head.first, headers)

    def frames(self):
        """The body as it arrives: `(raw, data, last)` for each piece, `raw` as relayed (chunk framing kept), `data`
        its payload, and `last` true only for a chunked body's last chunk (its end, never data)."""
        if self.empty:
            return
        if self.chunked:
            while True:
                size_line = self.reader.readline(1024)
                if not size_line:
                    raise Closed("the server closed inside a chunk")
                size = int(size_line.split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    trailer = size_line
                    while True:
                        line = self.reader.readline(MAX_HEAD)
                        trailer += line
                        if line in (b"\r\n", b"\n", b""):
                            break
                    yield trailer, b"", True
                    return
                piece = read_exact(self.reader, size + 2)
                yield size_line + piece, piece[:-2], False
        elif self.length is not None:
            left = self.length
            while left > 0:
                data = self.reader.read1(min(left, 65536))
                if not data:
                    raise Closed("the server closed inside a body")
                left -= len(data)
                yield data, data, False
        else:
            while True:
                data = self.reader.read1(65536)
                if not data:
                    return
                yield data, data, False

    def chunks(self):
        for raw, _, _ in self.frames():
            yield raw

    def body(self) -> bytes:
        return b"".join(self.chunks())

    @property
    def live_stream(self) -> bool:
        """An event stream the server keeps open: 2xx text/event-stream that is chunked or runs until closed. One framed
        by its length is a finite answer."""
        return self.streaming and 200 <= self.status < 300 and self.length is None and not self.empty

    def first_event(self) -> bytes | None:
        """Reads up to the end of the stream's first complete event (a blank line ends it, across chunks) and returns
        what was read as relayed; None when the stream ended first. `read` keeps what was read either way."""
        self.read = b""
        text = b""
        for raw, data, last in self.frames():
            self.read += raw
            if last:
                return None
            text += data
            if b"\n\n" in text.replace(b"\r\n", b"\n").replace(b"\r", b"\n"):
                return self.read
        return None

    def close(self) -> None:
        try:
            self.reader.close()
        except OSError:
            pass
        reset(self.sock)


# ---- rules

@dataclass
class Rule:
    id: int
    mode: str
    method: str | None = None
    path: str | None = None
    fact_type: str | None = None
    skip: int = 0
    count: int = 1
    options: dict = field(default_factory=dict)
    seen: int = 0
    fired: int = 0
    disarmed: bool = False
    failed: str | None = None
    release: threading.Event = field(default_factory=threading.Event)
    release_mode: str = "continue"

    def __post_init__(self) -> None:
        self.pattern = path_pattern(self.path) if self.path else None

    def matches(self, method: str, path: str, facts: list[dict]) -> bool:
        if self.disarmed or (self.count and self.fired >= self.count):
            return False
        if self.method and self.method.upper() != method.upper():
            return False
        if self.pattern and not self.pattern.match(path):
            return False
        if self.fact_type and not any(fact.get("type") == self.fact_type for fact in facts):
            return False
        return True

    def describe(self) -> dict:
        return {"rule": self.id, "mode": self.mode, "method": self.method, "path": self.path, "fact_type": self.fact_type,
                "skip": self.skip, "count": self.count, "seen": self.seen, "fired": self.fired,
                "state": "disarmed" if self.disarmed else "failed" if self.failed
                else "done" if self.count and self.fired >= self.count else "armed", "failure": self.failed,
                **{key: value for key, value in self.options.items() if key != "body"}}


@dataclass
class Hold:
    id: int
    rule: Rule
    request: int
    method: str
    path: str
    facts: list
    released: threading.Event = field(default_factory=threading.Event)
    mode: str = "continue"
    state: str = "held"


@dataclass
class Relay:
    """One request's connection to the server, registered before it connects, so a change of state reaches it at
    every step: refusal (and stop) cut it, silence cuts it, a dead stream cuts an event stream's."""
    client: socket.socket
    upstream: socket.socket
    stream: bool
    cut: str | None = None  # why it was cut: "refuse", "silent", "dead_events" or "stopped"


def push_facts(method: str, path: str, head: Head, body: bytes) -> list[dict]:
    """A push's facts as `{op_id, type}` (never payloads or secrets)."""
    if method != "POST" or not body or "json" not in (head.get("Content-Type") or ""):
        return []
    try:
        operations = json.loads(body).get("operations") or []
        return [{"op_id": op["fact"].get("op_id"), "type": op["fact"].get("type")}
                for op in operations if isinstance(op, dict) and isinstance(op.get("fact"), dict)]
    except (ValueError, AttributeError, TypeError):
        return []


class FaultProxy:
    def __init__(self, events, port: int, upstream: Callable[[], int | None], crash: Callable[[str, bool], None],
                 hang: Callable[[str], None]) -> None:
        """`upstream` is the server's private port, or None while no server runs; `crash(reason, restart)` kills it
        (and restarts it unless told not to); `hang(reason)` stops it."""
        self.events = events
        self.port = port
        self.upstream = upstream
        self.crash = crash
        self.hang = hang
        self.lock = threading.RLock()
        self.lifecycle_lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.state = "pass"
        self.dead_events = False
        self.rules: list[Rule] = []
        self.holds: dict[int, Hold] = {}
        self.rule_ids = itertools.count(1)
        self.hold_ids = itertools.count(1)
        self.request_ids = itertools.count(1)
        self.clients: dict[socket.socket, str] = {}
        self.relays: dict[socket.socket, Relay] = {}  # each client's open relay to the server
        self.listener: socket.socket | None = None
        self.accepting: threading.Thread | None = None
        self.workers: set[threading.Thread] = set()
        self.started = False
        self.stopped = False
        self.server_up = False
        self.after_body: Callable[[], object] | None = None  # the proxy's own tests: a barrier after a request's body

    # ---- lifecycle

    def start(self) -> None:
        if self.port == 0:  # an ephemeral port is chosen once and kept for the hub's life
            probe = socket.socket()
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
            probe.close()
        self.started = True
        self._update_listener()

    def stop(self) -> None:
        with self.lifecycle_lock:
            with self.lock:
                self.stopped = True
                self.changed.notify_all()
                for rule in self.rules:
                    rule.release.set()
                for hold in self.holds.values():
                    hold.released.set()
                relays = self._cut_relays("stopped")
                clients = list(self.clients)
            self._close_listener()
        for client in clients:
            cut(client)
        for relay in relays:
            cut(relay.upstream)
        deadline = time.monotonic() + 30
        with self.lock:
            workers = list(self.workers)
        for worker in workers:
            worker.join(max(0, deadline - time.monotonic()))
        if any(worker.is_alive() for worker in workers):
            raise RuntimeError("proxy request workers did not exit")

    def _cut_relays(self, why: str, streams_only: bool = False) -> list[Relay]:
        """Marks the open relays cut (under the lock); the caller shuts their server connections down."""
        chosen = [relay for relay in self.relays.values() if relay.stream or not streams_only]
        for relay in chosen:
            relay.cut = relay.cut or why
        return chosen

    def server_changed(self, running: bool, graceful: bool = True) -> None:
        """The hub started or stopped the server. While none runs, connections are refused and idle ones closed."""
        with self.lock:
            self.server_up = running
            idle = [client for client, state in self.clients.items() if state == "idle"] if not running else []
        for client in idle:
            if graceful:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            else:
                cut(client)
        self._update_listener()

    def set_state(self, state: str) -> None:
        """`refuse` closes the listener and every open connection (kept, streaming, held or parked; a held request is
        never forwarded); `silent` applies to every request from now on, on connections opened before it too, and an
        open event stream relays nothing more."""
        if state not in STATES:
            raise ValueError(f"state must be one of {sorted(STATES)}")
        with self.lock:
            # One transition under the lock: a request is forwarded only while the state is "pass" (`_exchange` checks
            # under this lock), and every relay open now is cut, so nothing is forwarded or answered after it.
            previous, self.state = self.state, state
            self.changed.notify_all()
            relays = self._cut_relays(state) if state != "pass" else []
            open_clients: list[socket.socket] = []
            if state == "refuse":
                for hold in self.holds.values():
                    if hold.state == "held":
                        hold.mode = "drop_request"
                        hold.released.set()
                open_clients = list(self.clients)
        self._update_listener()
        for client in open_clients:
            cut(client)
        for relay in relays:  # a relay connecting, sending, or waiting on the server ends too
            cut(relay.upstream)
        self.events.emit("proxy", "state", state=state, previous=previous)

    def set_dead_events(self, dead: bool) -> None:
        with self.lock:
            self.dead_events = dead
            self.changed.notify_all()
            relays = self._cut_relays("dead_events", streams_only=True) if dead else []
        for relay in relays:  # an open event stream's wait on the server ends; its client stays, unanswered
            cut(relay.upstream)
        self.events.emit("proxy", "dead_events", dead=dead)

    def _update_listener(self) -> None:
        with self.lifecycle_lock:
            with self.lock:
                want = self.started and not self.stopped and self.server_up and self.state != "refuse"
                have = self.listener is not None
            if want and not have:
                self._open_listener()
            elif have and not want:
                self._close_listener()

    def _open_listener(self) -> None:
        with self.lifecycle_lock:
            with self.lock:
                if self.stopped or self.listener is not None or not self.server_up or self.state == "refuse":
                    return
            self._open_listener_locked()

    def _open_listener_locked(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        for _ in range(100):
            try:
                listener.bind(("127.0.0.1", self.port))
                break
            except OSError:
                with self.changed:
                    self.changed.wait(0.05)  # bounded wait for the previous listener's port to be released
        else:
            raise OSError(f"the proxy cannot bind 127.0.0.1:{self.port}")
        listener.listen(256)
        with self.lock:
            self.listener = listener
        self.accepting = threading.Thread(target=self._accept, args=(listener,), daemon=True)
        self.accepting.start()

    def _close_listener(self) -> None:
        with self.lock:
            listener, self.listener = self.listener, None
            accepting, self.accepting = self.accepting, None
        if accepting and accepting is not threading.current_thread():
            accepting.join(timeout=5)
            if accepting.is_alive():
                raise RuntimeError("proxy listener thread did not exit")
        if listener:
            listener.close()

    def _accept(self, listener: socket.socket) -> None:
        while True:
            with self.lock:
                if self.listener is not listener:
                    return
            try:
                ready, _, _ = select.select([listener], [], [], 0.1)
            except (OSError, ValueError):
                return
            if not ready:
                continue
            try:
                client, _ = listener.accept()
            except OSError:
                continue
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                if self.stopped or self.listener is not listener:
                    cut(client)
                    return
                self.clients[client] = "idle"
                worker = threading.Thread(target=self._serve_owned, args=(client,), daemon=True)
                self.workers.add(worker)
                worker.start()

    def _serve_owned(self, client: socket.socket) -> None:
        try:
            self._serve(client)
        finally:
            with self.lock:
                self.workers.discard(threading.current_thread())

    # ---- rules and holds

    def arm(self, spec: dict) -> dict:
        mode = spec.get("mode")
        if mode not in REQUEST_MODES:
            raise ValueError(f"mode must be one of {sorted(REQUEST_MODES)}")
        known = {"mode", "method", "path", "fact_type", "skip", "count"}
        options = {key: value for key, value in spec.items() if key not in known}
        with self.lock:
            rule = Rule(id=next(self.rule_ids), mode=mode, method=spec.get("method"), path=spec.get("path"),
                        fact_type=spec.get("fact_type"), skip=int(spec.get("skip", 0)), count=int(spec.get("count", 1)),
                        options=options)
            self.rules.append(rule)
        description = rule.describe()
        self.events.emit("proxy", "armed", **description)
        return description

    def disarm(self, rule_id: int | None = None) -> list[dict]:
        """Disarms one rule (or all); what it holds is let go: held requests continue, silent ones are reset."""
        with self.lock:
            chosen = [rule for rule in self.rules if rule_id is None or rule.id == rule_id]
            for rule in chosen:
                rule.disarmed = True
                rule.release.set()
            for hold in self.holds.values():
                if hold.rule in chosen and hold.state == "held":
                    hold.mode = "continue"
                    hold.released.set()
            self.rules = [rule for rule in self.rules if rule not in chosen]
        for rule in chosen:
            self.events.emit("proxy", "disarmed", rule=rule.id)
        return [rule.describe() for rule in chosen]

    def describe(self) -> dict:
        with self.lock:
            return {"port": self.port, "state": self.state, "dead_events": self.dead_events, "server_up": self.server_up,
                    "listening": self.listener is not None, "rules": [rule.describe() for rule in self.rules],
                    "holds": [{"hold": hold.id, "rule": hold.rule.id, "method": hold.method, "path": hold.path,
                               "state": hold.state} for hold in self.holds.values()]}

    def release(self, hold_id: int, mode: str = "continue") -> dict:
        if mode not in ("continue", "drop_request", "drop_answer"):
            raise ValueError("mode is continue, drop_request or drop_answer")
        with self.lock:
            hold = self.holds.get(hold_id)
            if hold is None:
                raise KeyError(f"no hold {hold_id}")
            if hold.state == "held":
                hold.mode = mode
                hold.released.set()
            return {"hold": hold.id, "state": hold.state, "mode": mode}

    def release_rule(self, rule_id: int) -> dict:
        """Lets go of what a stall or silent rule holds (their connections are reset)."""
        with self.lock:
            for rule in self.rules:
                if rule.id == rule_id:
                    rule.release.set()
                    return rule.describe()
        raise KeyError(f"no rule {rule_id}")

    def _failed(self, rule: Rule, reason: str) -> None:
        """A fault that could not happen as asked: the request goes on unfaulted, and the rule says why."""
        with self.lock:
            rule.failed = reason
        self.events.emit("proxy", "fault_failed", rule=rule.id, mode=rule.mode, reason=reason)

    def _take(self, method: str, path: str, facts: list[dict]) -> Rule | None:
        with self.lock:
            for rule in self.rules:
                if rule.matches(method, path, facts):
                    rule.seen += 1
                    if rule.seen <= rule.skip:
                        continue
                    rule.fired += 1
                    return rule
        return None

    def _wait(self, released: threading.Event, condition: Callable[[], bool] | None = None,
              client: socket.socket | None = None) -> None:
        """Waits until `released` is set, the proxy stops, `condition` (checked under the lock) becomes false, or the
        `client` (when given) goes away."""
        while not released.is_set():
            with self.lock:
                if self.stopped or (condition is not None and not condition()):
                    return
                self.changed.wait(0.1)
            if client is not None and gone(client):
                return

    # ---- a client connection

    def _serve(self, client: socket.socket) -> None:
        """Requests on one client connection. It ends with an orderly close after a complete answer the client asked
        to close after, and with a reset otherwise (a fault, a dead server, the client going away)."""
        reader = client.makefile("rb")
        graceful = False
        try:
            while True:
                with self.lock:
                    silent = self.state == "silent"
                if silent:
                    self._park(client, lambda: self.state == "silent")
                    return
                lines = read_head(reader)
                if lines is None:
                    return
                with self.lock:
                    self.clients[client] = "busy"
                    state = self.state
                if state == "refuse":  # a request that raced the refusal is never forwarded
                    return
                if state == "silent":  # a request on a connection that was open before the silence
                    self._park(client, lambda: self.state == "silent")
                    return
                head = Head(lines)
                method, target, version = (head.first.split(" ", 2) + ["", ""])[:3]
                if (head.get("Expect") or "").lower() == "100-continue":
                    client.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
                body = read_body(reader, head)
                if self.after_body:
                    self.after_body()
                keep_alive = version == "HTTP/1.1" and (head.get("Connection") or "").lower() != "close"
                outcome = self._request(client, head, method, target, body, keep_alive)
                if outcome == "close":  # the answer is complete: an orderly close
                    graceful = True
                    return
                if outcome != "keep":
                    return
                with self.lock:
                    self.clients[client] = "idle"
        except (Closed, OSError, ValueError):
            pass
        except Exception as error:  # a fault the hub could not carry out (the server was not running to be killed)
            self.events.emit("proxy", "error", error=f"{type(error).__name__}: {error}")
        finally:
            with self.lock:
                self.clients.pop(client, None)
            try:
                reader.close()
            except OSError:
                pass
            if graceful:
                try:
                    client.shutdown(socket.SHUT_WR)
                    client.close()
                except OSError:
                    reset(client)
            else:
                reset(client)

    def _park(self, client: socket.socket, condition: Callable[[], bool], released: threading.Event | None = None) -> None:
        """Answers nothing until released (or the condition ends); the connection is then reset."""
        with self.lock:
            self.clients[client] = "parked"
        self._wait(released or threading.Event(), condition, client)

    def _request(self, client: socket.socket, head: Head, method: str, target: str, body: bytes, keep_alive: bool) -> str:
        """Handles one request. Returns what becomes of the connection: "keep", "close" or "reset"."""
        number = next(self.request_ids)
        path = target.split("?", 1)[0]
        logged = redact(target)
        started = time.monotonic()
        result: dict = {"outcome": "relayed"}

        def log(**fields) -> None:
            self.events.emit("proxy", "request", request=number, method=method, path=logged,
                             ms=int((time.monotonic() - started) * 1000), **result, **fields)

        with self.lock:  # the state may have changed while the body was read
            state, dead = self.state, self.dead_events and path == "/v1/events"
        if state != "pass" or dead:
            return self._withheld(client, "refuse" if state == "refuse" else "silent" if state == "silent" else "dead_events",
                                  result, log)
        facts = push_facts(method, path, head, body)
        rule = self._take(method, path, facts)
        if rule is None:
            return self._forward(client, head, method, target, body, keep_alive, result, log)
        result.update(rule=rule.id, mode=rule.mode)
        self.events.emit("proxy", "fault", request=number, rule=rule.id, mode=rule.mode, method=method, path=logged,
                         facts=[fact.get("type") for fact in facts] or None)
        mode, options = rule.mode, rule.options

        if mode == "drop_request":
            result["outcome"] = "dropped"
            log()
            return "reset"
        if mode in ("busy", "captive", "status"):
            if mode == "busy":
                wait = int(options.get("retry_after", 2))
                status, payload, kind = 503, json.dumps({"error": "server_busy", "message": "The server is busy; try again shortly.",
                                                         "retry_after": wait}).encode(), "application/json"
                extra = [("Retry-After", str(wait))]
            elif mode == "captive":
                status, payload, kind, extra = 200, CAPTIVE, "text/html; charset=utf-8", []
            else:
                status = int(options.get("status", 500))
                payload, kind, extra = json.dumps(options.get("body", {})).encode(), "application/json", []
            headers = [("Content-Type", kind), ("Content-Length", str(len(payload)))] + extra
            if not keep_alive:
                headers.append(("Connection", "close"))
            with self.lock:
                state = self.state
            if state != "pass":  # the proxy's own answer is not given after a refusal or during a silence either
                return self._withheld(client, state, result, log)
            client.sendall(Head.encode(f"HTTP/1.1 {status} {_phrase(status)}", headers) + payload)
            result["outcome"] = "answered"
            log(status=status)
            return "keep" if keep_alive else "close"
        if mode == "silent":
            result["outcome"] = "silent"
            log()
            self._park(client, lambda: not rule.disarmed, rule.release)
            return "reset"
        if mode == "hold":
            with self.lock:
                hold = Hold(id=next(self.hold_ids), rule=rule, request=number, method=method, path=logged,
                            facts=[fact.get("type") for fact in facts])
                self.holds[hold.id] = hold
                self.clients[client] = "held"
            self.events.emit("proxy", "held", hold=hold.id, rule=rule.id, request=number, method=method, path=logged,
                             facts=hold.facts or None)
            self._wait(hold.released)
            with self.lock:
                hold.state = "released"
                self.clients[client] = "busy"
            self.events.emit("proxy", "released", hold=hold.id, rule=rule.id, request=number, release=hold.mode)
            result["release"] = hold.mode
            if hold.mode == "drop_request":
                result["outcome"] = "dropped"
                log()
                return "reset"
            if hold.mode == "drop_answer":
                return self._forward(client, head, method, target, body, keep_alive, result, log, drop_answer=True)
            return self._forward(client, head, method, target, body, keep_alive, result, log)
        if mode == "crash_before":
            self.crash(f"proxy rule {rule.id}: before {method} {logged}", bool(options.get("restart", True)))
            result["outcome"] = "server_killed"
            log()
            return "reset"
        if mode == "hang_before":
            self.hang(f"proxy rule {rule.id}: before {method} {logged}")
            return self._forward(client, head, method, target, body, keep_alive, result, log)
        if mode == "drop_answer":
            return self._forward(client, head, method, target, body, keep_alive, result, log, drop_answer=True)
        if mode == "crash_after":
            return self._forward(client, head, method, target, body, keep_alive, result, log,
                                 crash_after=(rule, bool(options.get("restart", True))))
        if mode == "duplicate":
            first = self._exchange(client, head, method, target, body)
            if isinstance(first, str):
                return self._withheld(client, first, result, log)
            first_status = first.status
            try:
                first.first_event() if first.live_stream else first.body()
            except Closed:
                pass
            finally:
                cut_by = self._unregister(client)
                first.close()
            if cut_by:
                return self._withheld(client, cut_by, result, log)
            result["first_status"] = first_status
            return self._forward(client, head, method, target, body, keep_alive, result, log)
        if mode == "stall":
            return self._forward(client, head, method, target, body, keep_alive, result, log, stall=rule)
        raise ValueError(mode)

    def _admitted(self, relay: Relay | None) -> str | None:
        """Under the lock: why a request may not go on now ("refuse", "silent", "dead_events", "stopped"), or None."""
        if relay is not None and relay.cut:
            return relay.cut
        if self.stopped:
            return "stopped"
        if self.state != "pass":
            return self.state
        if relay is not None and relay.stream and self.dead_events:
            return "dead_events"
        return None

    def _unregister(self, client: socket.socket) -> str | None:
        """Ends a client's relay; returns why it was cut, if it was."""
        with self.lock:
            relay = self.relays.pop(client, None)
        return relay.cut if relay else None

    def _exchange(self, client: socket.socket, head: Head, method: str, target: str, body: bytes) -> Answer | str:
        """Sends the request to the server on a new connection, registered for the client before it connects, and
        reads the answer's head. On failure returns why: "no_server", or the change of state that stopped it (a
        request leaves only while the proxy passes; one cut while connecting, sending or waiting goes no further).
        On success the relay stays registered until the caller unregisters it."""
        port = self.upstream()
        if port is None:
            return "no_server"
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        relay = Relay(client, upstream, stream=target.split("?", 1)[0] == "/v1/events")
        with self.lock:
            refused = self._admitted(relay)
            if not refused:
                self.relays[client] = relay
        if refused:
            upstream.close()
            return refused
        try:
            upstream.settimeout(5)
            upstream.connect(("127.0.0.1", port))
            upstream.settimeout(None)
            upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            headers = head.without("Connection", "Keep-Alive", "Proxy-Connection", "Expect", "Transfer-Encoding", "Content-Length")
            if body or method in ("POST", "PUT", "PATCH"):
                headers.append(("Content-Length", str(len(body))))
            headers.append(("Connection", "close"))
            with self.lock:  # the last check: a change of state from here on cuts the connection under the request
                refused = self._admitted(relay)
            if refused:
                raise Closed(refused)
            upstream.sendall(Head.encode(head.first, headers) + body)
            return Answer(upstream, method)
        except (OSError, Closed):
            cut_by = self._unregister(client)
            reset(upstream)
            with self.lock:
                return relay.cut or cut_by or self._admitted(None) or "no_server"

    def _withheld(self, client: socket.socket, why: str, result: dict, log) -> str:
        """A request the state stops: refused (reset), or held unanswered while silent or while the stream is dead
        (watching for the client going away), then reset."""
        if why in ("silent", "dead_events"):
            result["outcome"] = why
            log()
            self._park(client, (lambda: self.state == "silent") if why == "silent" else (lambda: self.dead_events))
            return "reset"
        result["outcome"] = {"refuse": "refused", "stopped": "stopped"}.get(why, why)
        log()
        return "reset"

    def _silenced(self, relay_client: socket.socket) -> str | None:
        """Whether what the server answers must not be relayed now: silence, or a cut relay."""
        with self.lock:
            relay = self.relays.get(relay_client)
            if relay is not None and relay.cut:
                return relay.cut
            return "silent" if self.state == "silent" else None

    def _forward(self, client, head, method, target, body, keep_alive, result, log, drop_answer=False,
                 crash_after=None, stall: Rule | None = None) -> str:
        answer = self._exchange(client, head, method, target, body)
        if isinstance(answer, str):
            return self._withheld(client, answer, result, log)
        try:
            if drop_answer or crash_after:
                # The server has answered: a finite answer once all of it arrived; a live event stream (which the
                # server keeps open) once its head and first event arrived. Nothing of it is relayed.
                boundary, read = "whole answer", 0
                try:
                    if answer.live_stream:
                        boundary = "first event" if answer.first_event() is not None else "stream ended"
                        read = len(answer.read)
                    else:
                        read = len(answer.body())
                except Closed:
                    pass
                cut_by = self._silenced(client)
                if cut_by:  # cut while waiting for the answer: no kill, no answer
                    return self._withheld(client, cut_by, result, log)
                if crash_after:
                    rule, restart = crash_after
                    self.crash(f"proxy rule {rule.id}: after {method} {redact(target)} answered {answer.status} "
                               f"({boundary})", restart)
                    result["outcome"] = "server_killed"
                else:
                    result["outcome"] = "answer_dropped"
                log(server_status=answer.status, boundary=boundary, read_bytes=read)
                return "reset"
            if stall is not None and answer.live_stream:
                # A stream stalls after its first event: the head and that event are relayed, then nothing.
                first = answer.first_event()
                if self._silenced(client):
                    return self._withheld(client, self._silenced(client), result, log)
                if first is None:  # it ended: the answer is complete, and a stall cannot happen
                    reason = "the event stream ended before its first complete event"
                    self._failed(stall, reason)
                    client.sendall(answer.client_head(keep_alive) + answer.read)
                    log(status=answer.status, fault_failed=reason)
                    return "keep" if keep_alive and not answer.until_close else "close"
                client.sendall(answer.client_head(False) + first)
                result["outcome"] = "stalled"
                log(status=answer.status, relayed_bytes=len(first), boundary="first event")
                self._park(client, lambda: not stall.disarmed, stall.release)
                return "reset"
            if stall is not None:
                # The body as relayed (chunk framing included); the cut must leave the answer incomplete.
                data = answer.body()
                if self._silenced(client):
                    return self._withheld(client, self._silenced(client), result, log)
                cut = stall.options.get("after_bytes")
                cut = len(data) // 2 if cut is None else int(cut)
                if not 0 <= cut < len(data):
                    reason = (f"the answer has no body to stall in" if not data
                              else f"a cut after {cut} bytes would deliver all {len(data)} bytes of the answer")
                    self._failed(stall, reason)
                    client.sendall(answer.client_head(keep_alive) + data)
                    log(status=answer.status, fault_failed=reason)
                    return "keep" if keep_alive and not answer.until_close else "close"
                client.sendall(answer.client_head(False) + data[:cut])
                result["outcome"] = "stalled"
                log(status=answer.status, relayed_bytes=cut, body_bytes=len(data))
                self._park(client, lambda: not stall.disarmed, stall.release)
                return "reset"
            if self._silenced(client):  # not even the head while silent
                return self._withheld(client, self._silenced(client), result, log)
            client.sendall(answer.client_head(keep_alive))
            if answer.streaming:
                return self._stream(client, answer, result, log)
            for chunk in answer.chunks():
                if self._silenced(client):  # a finite answer stops too
                    return self._withheld(client, self._silenced(client), result, log)
                client.sendall(chunk)
            log(status=answer.status)
            return "keep" if keep_alive and not answer.until_close else "close"
        except Closed:
            cut_by = self._silenced(client)
            if cut_by:
                return self._withheld(client, cut_by, result, log)
            result["outcome"] = "server_closed"
            log(status=answer.status)
            return "reset"
        finally:
            self._unregister(client)
            answer.close()

    def _stream(self, client, answer: Answer, result, log) -> str:
        """An event stream, relayed as it arrives, until it ends, the stream is made dead or the proxy goes silent. A
        dead or silenced stream stays open and relays nothing more, also when the server behind it goes away."""
        def frozen() -> bool:
            return self.dead_events or self.state == "silent"

        closed = False
        try:
            for chunk in answer.chunks():
                with self.lock:
                    stop = frozen()
                if stop:
                    break
                client.sendall(chunk)
        except Closed:
            closed = True
        with self.lock:
            stop = frozen()
            outcome = "dead_events" if self.dead_events else "silent"
        if not stop:
            if closed:
                result["outcome"] = "server_closed"
            log(status=answer.status)
            return "reset" if closed else "close"
        answer.close()
        result["outcome"] = outcome
        log(status=answer.status)
        self._park(client, frozen)
        return "reset"
