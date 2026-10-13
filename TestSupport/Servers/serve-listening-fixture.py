"""Static `TestSupport/Media/listening` server on 127.0.0.1:18765 with every extra route the UI tests use.

Combines the former separate 18765 servers, whose routes never overlap:
- FeedRefreshTests: `/feed.xml?edited=1` (refreshed channel with one delivered episode);
- OnlineSearchTests: `/directory/*` search/lookup JSON and `/online-feed.xml`;
- everything else: the static listening fixture files.
Run from the repository root (Tools/test-fixtures.sh does).
"""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import sys

PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 18765
LISTENING = "TestSupport/Media/listening"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=LISTENING, **kw)

    def send_body(self, body, mime):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        if self.path == "/feed.xml?edited=1":
            body = Path(LISTENING, "feed.xml").read_text().replace("Parity Listening Lab", "Refreshed Listening Lab").replace(
                "<channel>", "<channel><item><guid>refresh-delivered</guid><title>Refresh delivered episode</title></item>")
            self.send_body(body.encode(), "application/rss+xml")
        elif parsed.path.startswith("/directory/"):
            if parsed.path == "/directory/lookup":
                track = "No exact title" if parse_qs(parsed.query).get("id") == ["999"] else "Online podcast 0"
                self.send_body(json.dumps({"results": [{"artistName": "Fixture author", "trackName": track}]}).encode(), "application/json")
                return
            query = parse_qs(parsed.query).get("term", parse_qs(parsed.query).get("q", [""]))[0]
            apple = parsed.path.endswith("apple")
            results = []
            if query not in ("unfindable", "zz9c7fzz"):
                for i in range(24):
                    feed = f"http://127.0.0.1:{PORT}/online-feed.xml" + ("" if i == 0 else f"?n={i}")
                    results.append({"collectionName": f"Online podcast {i}", "feedUrl": feed, "artistName": "Fixture author"} if apple
                                   else {"title": f"Online podcast {i}", "url": feed, "author": "Fixture author"})
            self.send_body(json.dumps({"results" if apple else "feeds": results}).encode(), "application/json")
        elif parsed.path == "/online-feed.xml":
            body = Path(LISTENING, "feed.xml").read_text().replace("Parity Listening Lab", "Online Listening Lab").replace(
                "parity-intro", "online-intro").replace("parity-queue", "online-queue")
            self.send_body(body.encode(), "application/rss+xml")
        else:
            super().do_GET()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
