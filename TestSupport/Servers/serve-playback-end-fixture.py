"""Loopback fixture on 127.0.0.1:18778 for the end-of-episode and kill-while-playing journeys.

`/feed.xml?run=<id>` starts at stage 0 with one 60-second "Earlier episode". After
`/advance?run=<id>&stage=1` the same feed also lists three newer episodes (A 8 s, B 20 s,
C 8 s, newest first), so a refresh delivers them to the Inbox as Android's FeedDatabaseWriter
does for episodes newer than the prior most recent one. `/media/<name>.mp3?run=<id>` serves
full files (no ranges). Each run id is isolated. Media: docs/TESTING.md.
Run from the repository root (Tools/test-fixtures.sh does).
"""
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape

PORT = 18778
ROOT = Path(__file__).resolve().parents[2]
MEDIA = {
    "tone-8sec": ROOT / "TestSupport/Media/playback-end/tone-8sec.mp3",
    "tone-20sec": ROOT / "TestSupport/Media/playback-end/tone-20sec.mp3",
    "tone-60sec": ROOT / "TestSupport/Media/listening/sync-60sec.mp3",
}
# guid, title, publication day (January 2001), media, seconds, first stage that lists it
EPISODES = [
    ("end-a", "Episode A", 4, "tone-8sec", 8, 1),
    ("end-b", "Episode B", 3, "tone-20sec", 20, 1),
    ("end-c", "Episode C", 2, "tone-8sec", 8, 1),
    ("end-earlier", "Earlier episode", 1, "tone-60sec", 60, 0),
]
stages, lock = {}, Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        run = query.get("run", [""])[0]
        if url.path == "/advance":
            with lock:
                stages[run] = int(query.get("stage", ["1"])[0])
                data = str(stages[run]).encode()
            mime = "text/plain"
        elif url.path == "/feed.xml":
            with lock:
                stage = stages.get(run, 0)
            items = "".join(
                f"<item><guid>{guid}</guid><title>{escape(title)}</title>"
                f"<pubDate>{date(2001, 1, day).strftime('%a')}, {day:02} Jan 2001 12:00:00 GMT</pubDate>"
                f"<itunes:duration>{seconds}</itunes:duration>"
                f'<enclosure url="http://127.0.0.1:{PORT}/media/{guid}.mp3?run={escape(run)}" type="audio/mpeg" '
                f'length="{MEDIA[media].stat().st_size}"/></item>'
                for guid, title, day, media, seconds, first in EPISODES if first <= stage)
            data = ('<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                    "<title>Episode End Lab</title><description>Short episodes that play to their end</description>"
                    f"{items}</channel></rss>").encode()
            mime = "application/rss+xml"
        elif url.path.startswith("/media/") and url.path.endswith(".mp3"):
            guid = url.path[len("/media/"):-len(".mp3")]
            match = next((media for g, _, _, media, _, _ in EPISODES if g == guid), None)
            if match is None:
                self.send_error(404)
                return
            data, mime = MEDIA[match].read_bytes(), "audio/mpeg"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if body:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
