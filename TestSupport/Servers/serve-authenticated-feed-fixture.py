"""Synthetic Basic-auth preview fixture. Counts outcomes; never logs credentials."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit
from collections import defaultdict
from threading import Lock
import base64
import json

counts = defaultdict(lambda: {"attempts": 0, "authorized": 0})
lock = Lock()
authorizations = {"Basic " + base64.b64encode(value).decode() for value in (b"listener:podcast", b"listener:updated-podcast")}

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="TestSupport/Media/listening", **kwargs)

    def do_GET(self):
        route = urlsplit(self.path)
        if route.path == "/counts":
            with lock:
                body = json.dumps(dict(counts)).encode()
            self.reply(200, body, "application/json")
            return
        authorized = self.headers.get("Authorization") in authorizations
        with lock:
            counts[self.path]["attempts"] += 1
            counts[self.path]["authorized"] += int(authorized)
        if not authorized:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Preview fixture", charset="UTF-8"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route.path == "/private.xml":
            base = "http://" + self.headers["Host"]
            items = ''.join(f'<item><guid>private-{i}</guid><title>Private episode {i:02}</title><description>Private episode notes</description><pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate><enclosure url="{base}/30sec.mp3?episode={i}" type="audio/mpeg" length="120000"/></item>' for i in range(12, 0, -1))
            body = f'<rss version="2.0"><channel><title>Authentication Lab</title><description>A controlled authenticated podcast.</description>{items}</channel></rss>'.encode()
            self.reply(200, body, "application/rss+xml")
        else:
            super().do_GET()

    def reply(self, code, body, mime):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

ThreadingHTTPServer(("0.0.0.0", 18770), Handler).serve_forever()
