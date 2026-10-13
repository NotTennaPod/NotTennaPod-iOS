"""Shared pieces of the hub's own tests: a scripted upstream standing in for the server, and raw HTTP clients that
show exactly what a client sees (an answer, a reset, a refusal or silence)."""

from __future__ import annotations

import json
import socket
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from hub.events import EventLog


SPLIT_EVENT = (b"event: ", b"changed\ndata: {}\n\n")


def framed(parts) -> bytes:
    return b"".join(b"%x\r\n%s\r\n" % (len(part), part) for part in parts)


def free_port() -> int:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class FakeUpstream:
    """A stand-in server: `/ok` (a length), `/chunked`, `/v1/events` (an event stream that stays open until told),
    `/v1/push` (counts and echoes the body)."""

    def __init__(self) -> None:
        self.requests: list[tuple[str, str, bytes]] = []
        self.lock = threading.Lock()
        self.release_stream = threading.Event()
        self.stream_open = threading.Event()
        self.withheld = threading.Event()  # set once /withhold has read its request and withholds the answer
        upstream = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args) -> None:
                pass

            def do_GET(self) -> None:
                self.handle_request(b"")

            def do_POST(self) -> None:
                self.handle_request(self.rfile.read(int(self.headers.get("Content-Length") or 0)))

            def handle_request(self, body: bytes) -> None:
                with upstream.lock:
                    upstream.requests.append((self.command, self.path, body))
                path = self.path.split("?")[0]
                if path == "/chunked":
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    for part in (b"one,", b"two,", b"three"):
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                    self.wfile.write(b"0\r\n\r\n")
                    return
                if path == "/withhold":
                    # Reads the request and withholds every byte of the answer until the stream is released.
                    upstream.withheld.set()
                    upstream.release_stream.wait(30)
                    return
                if path in ("/sse-empty", "/sse-split"):
                    # An event stream that ends at once (only the last chunk), or whose first event is split.
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    if path == "/sse-empty":
                        self.wfile.write(b"0\r\n\r\n")
                        return
                    for part in SPLIT_EVENT:
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                        self.wfile.flush()
                    upstream.stream_open.set()
                    upstream.release_stream.wait(30)
                    try:
                        self.wfile.write(b"0\r\n\r\n")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if path == "/sse-length":
                    # An event stream framed by its length: a finite answer.
                    data = b"event: changed\ndata: {}\n\n"
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if path == "/v1/events":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    event = b"event: changed\ndata: {}\n\n"
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(event), event))
                    self.wfile.flush()
                    upstream.stream_open.set()
                    upstream.release_stream.wait(30)
                    try:
                        self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(event), event))
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # the proxy let go of the stream (a kill, a lost answer)
                    return
                data = json.dumps({"path": path, "echo": body.decode() or None}).encode()
                if path == "/big":
                    data = b"x" * 10000
                if path == "/empty":
                    data = b""
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    def count(self, path: str) -> int:
        with self.lock:
            return sum(1 for _, seen, _ in self.requests if seen.split("?")[0] == path)

    def stop(self) -> None:
        self.release_stream.set()
        self.server.shutdown()
        self.server.server_close()


def raw(port: int, request: bytes, timeout: float = 5.0) -> tuple[str, bytes]:
    """Sends one request on a new connection. Returns ("answer", bytes), ("reset", partial bytes), ("closed", bytes),
    ("refused", b"") or ("silent", partial bytes) when nothing more came within `timeout`."""
    sock = socket.socket()
    sock.settimeout(timeout)
    try:
        sock.connect(("127.0.0.1", port))
    except ConnectionRefusedError:
        return "refused", b""
    received = b""
    try:
        sock.sendall(request)
        while True:
            data = sock.recv(65536)
            if not data:
                return ("answer" if received else "closed"), received
            received += data
    except ConnectionResetError:
        return "reset", received
    except socket.timeout:
        return "silent", received
    finally:
        sock.close()


def get(path: str, method: str = "GET", body: bytes = b"", headers: dict | None = None) -> bytes:
    lines = [f"{method} {path} HTTP/1.1", "Host: 127.0.0.1", "Connection: close"]
    if body or method == "POST":
        lines += ["Content-Type: application/json", f"Content-Length: {len(body)}"]
    lines += [f"{key}: {value}" for key, value in (headers or {}).items()]
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


def call(base: str, method: str, path: str, body: dict | None = None, timeout: float = 120) -> tuple[int, dict]:
    data = json.dumps(body or {}).encode() if method == "POST" else None
    request = urllib.request.Request(base + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            return answer.status, json.loads(answer.read() or b"{}")
    except urllib.error.HTTPError as error:
        with error:
            return error.code, json.loads(error.read() or b"{}")


def events() -> EventLog:
    return EventLog()
