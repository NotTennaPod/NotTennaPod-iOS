"""Loopback-only deterministic chapter UI fixture; unchanged30s MP3 bytes."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import struct
import zlib

root = Path(__file__).resolve().parents[2]
media = (root / "Tests/NotTennaPodCoreTests/Fixtures/playback-30sec.mp3").read_bytes()


def solid_png(width, height, color):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    rows = (b"\0" + bytes(color) * width) * height
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ["/feed.xml", "/rich-feed.xml", "/failed-link-feed.xml", "/text-feed.xml"]:
            rich = path == "/rich-feed.xml"
            chapter_file = "failed-link-chapters.json" if path == "/failed-link-feed.xml" else ("rich-chapters.json" if rich else "chapters.json")
            if path == "/text-feed.xml": chapter_file = "text-chapters.json"
            feed_art = '<image><url>http://127.0.0.1:18807/feed-art.png</url></image>' if rich else ""
            content_type = "application/rss+xml"
            data = (f'<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>'
                    f'<title>Chapter parity</title><description>Chapter controls fixture</description>{feed_art}<item>'
                    f'<guid>chapters-one</guid><title>Chapter episode</title><description>Chapter playback fixture</description>'
                    f'<enclosure url="http://127.0.0.1:18807/media.mp3" type="audio/mpeg" length="{len(media)}"/>'
                    f'<podcast:chapters url="http://127.0.0.1:18807/{chapter_file}" type="application/json+chapters"/>'
                    f'</item></channel></rss>').encode()
        elif path == "/chapters.json":
            content_type = "application/json"
            data = json.dumps({"version": "1.2.0", "chapters": [
                {"startTime": 0, "title": "Opening"}, {"startTime": 10, "title": "Middle"},
                {"startTime": 20, "title": "Closing"}]}).encode()
        elif path == "/text-chapters.json":
            content_type = "application/json"
            titles = ["This deliberately long chapter title wraps over several lines and must stop at the second line with an ellipsis", "Opening\nSecond line", ""]
            data = json.dumps({"version":"1.2.0", "chapters":[
                {"startTime":i,"title":titles[i] if i < 3 else f"Chapter {i} with a long title that wraps onto another line", "url":f"https://example.invalid/chapter/{i}?long=link"}
                for i in range(20)]}).encode()
        elif path == "/failed-link-chapters.json":
            content_type = "application/json"
            data = json.dumps({"version":"1.2.0", "chapters":[
                {"startTime":0,"title":"Unavailable destination","url":"antennapod-unhandled-test://chapter?one=1#part"},
                {"startTime":10,"title":"Middle"}]}).encode()
        elif path == "/rich-chapters.json":
            content_type = "application/json"
            data = json.dumps({"version":"1.2.0", "chapters":[
                {"startTime":0,"title":"Opening with a long chapter title that wraps onto a second line","img":"http://127.0.0.1:18807/chapter-wide.png","url":"http://127.0.0.1:18807/chapter-page?one=1#part"},
                {"startTime":10,"title":"Tall chapter art","img":"http://127.0.0.1:18807/chapter-tall.png"},
                {"startTime":20,"title":"Ordinary cover fallback"},
                {"startTime":25,"title":"Unavailable artwork","img":"http://127.0.0.1:18807/missing.png"}]}).encode()
        elif path in ["/chapter-wide.png","/chapter-tall.png","/feed-art.png"]:
            content_type = "image/png"
            data = {"/chapter-wide.png":lambda:solid_png(120,60,(224,32,48)),
                    "/chapter-tall.png":lambda:solid_png(60,120,(32,64,224)),
                    "/feed-art.png":lambda:solid_png(80,80,(32,160,64))}[path]()
        elif path == "/chapter-page":
            content_type, data = "text/html", b"<html><body><h1>Chapter destination</h1><p id='part'>Chapter link opened.</p></body></html>"
        elif path == "/media.mp3":
            content_type, data = "audio/mpeg", media
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("127.0.0.1", 18807), Handler).serve_forever()
