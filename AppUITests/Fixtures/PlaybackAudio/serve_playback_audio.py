"""Owned loopback fixture, adapted from TestSupport/Servers/serve-app-playback-fixture.py.

Serves the existing immutable MP3, ADTS and MP4 media through the real RSS/download flow.
No listener is opened with --check. The caller owns the explicit port and log.
"""
import argparse
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit

MEDIA = {
    "mp3": ("LongMP3/half-hour.mp3", "audio/mpeg", 1800, "71a127511889f1816645d95231cec28816c6b7f1358266e5737d6a4d7f72cb49"),
    "aac": ("LongNativeFormats/long.aac", "audio/aac", 368, "52fd5b535ac5ad96b27180aeb2bf6586bedf2c7a084f34e0e6f6b244d4eeba64"),
    "mp4": ("LongNativeFormats/long.m4a", "audio/mp4", 368, "1275e0bd46e1e89b7dda2679eeaa4cb33385b5df56868c5abb4477ddb01a87e6"),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures-root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=59431)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content, receipt = {}, {"media": {}, "requests": []}
    for kind, (name, mime, duration, digest) in MEDIA.items():
        data = (args.fixtures_root / name).read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, name
        content[kind] = data
        receipt["media"][kind] = {"path": name, "mime": mime, "declaredSeconds": duration,
                                  "bytes": len(data), "sha256": digest}
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    if args.check:
        print("Verified all three immutable media fixtures; no listener opened")
        return
    lock = Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self.respond(False)

        def do_GET(self):
            self.respond(True)

        def respond(self, body):
            route = urlsplit(self.path)
            query = parse_qs(route.query)
            kind = query.get("format", [""])[0]
            run = query.get("run", [""])[0]
            if kind not in MEDIA or route.path not in ("/feed.xml", "/media"):
                self.send_error(404)
                return
            _, mime, duration, _ = MEDIA[kind]
            if route.path == "/feed.xml":
                data = (f'<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                        f'<title>Playback Audio {kind}</title><description>Controlled synthetic media</description><item>'
                        f'<guid>playback-audio-{kind}</guid><title>Playback {kind}</title>'
                        f'<itunes:duration>{duration}</itunes:duration>'
                        f'<enclosure url="http://127.0.0.1:{args.port}/media?format={kind}&amp;run={run}" '
                        f'type="{mime}" length="{len(content[kind])}"/></item></channel></rss>').encode()
                mime = "application/rss+xml"
            else:
                data = content[kind]
            with lock:
                receipt["requests"].append({"format": kind, "run": run, "path": route.path,
                                            "method": "GET" if body else "HEAD", "bytes": len(data)})
                args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if body:
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Playback audio fixture listening on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
