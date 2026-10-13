"""Loopback-only app playback fixture; media bytes are existing immutable fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import select
from threading import Lock

root = Path(__file__).resolve().parents[2]
media = {
    "download": root / "Tests/NotTennaPodCoreTests/Fixtures/LongMP3/half-hour.mp3",
    "live": root / "Tests/NotTennaPodCoreTests/Fixtures/playback-unknown-duration.mp3",
}
counts, lock = {}, Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, send_body):
        route = urlsplit(self.path)
        query = parse_qs(route.query)
        mode = query.get("mode", ["download"])[0]
        run = query.get("run", [""])[0]
        if route.path == "/counts":
            with lock:
                data = json.dumps(counts).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        elif mode not in media:
            self.send_error(404)
            return
        elif route.path == "/feed.xml":
            duration = "<itunes:duration>1800</itunes:duration>" if mode == "download" else ""
            size = media[mode].stat().st_size if mode == "download" else 0
            data = (f'<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                    f'<title>App Playback Lab</title><description>Controlled playback</description><item>'
                    f'<guid>{mode}</guid><title>{mode} episode</title>{duration}'
                    f'<enclosure url="http://127.0.0.1:18803/media?mode={mode}&amp;run={run}" '
                    f'type="audio/mpeg" length="{size}"/></item></channel></rss>').encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/rss+xml")
        elif route.path == "/media":
            with lock:
                entry = counts.setdefault(run, {"mode": mode, "gets": 0, "heads": 0})
                entry["gets" if send_body else "heads"] += 1
            data = media[mode].read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            if mode == "live":
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                if send_body:
                    try:
                        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                        self.wfile.flush()
                        # Deliberately withhold EOF. Retire only when the client closes.
                        while select.select([self.connection], [], [], 60)[0]:
                            if not self.connection.recv(1024):
                                break
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    self.close_connection = True
                return
        else:
            self.send_error(404)
            return
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if send_body:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

ThreadingHTTPServer(("127.0.0.1", 18803), Handler).serve_forever()
