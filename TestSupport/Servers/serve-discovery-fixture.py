"""Add-podcast discovery fixture server on 127.0.0.1:18820 (the oracle's default base).

Started by Tools/test-fixtures.sh for the UI tests; the app's DEBUG `-test-discovery` argument sends
Apple, Podcast Index and fyyd requests here (host → path prefix), and every UI-test launch sends the
Apple top list here, so no test reaches the live directories. All data is synthetic and comes from
TestSupport/Data/add-podcast-discovery (see docs/TESTING.md):

  /apple/<CC>/rss/toppodcasts/limit=25/explicit=true/json   the fixture top list (DE: German titles,
                                                            AQ: HTTP 400 "no data for the country")
  /apple/lookup?id=<n>                                      feedUrl → /feeds/top-<n>.xml on this server
  /apple/search?media=podcast&term=<q>                      combined case small_both, Apple half
  /podcastindex/api/1.0/search/byterm?q=<q>                 small_both, Podcast Index half (auth headers required)
  /fyyd/0.2/search/podcast?title=<q>&count=10               fyyd_only, feed URLs moved to this server
  /pages/<name>, /shows/index.html                          the classification pages with {BASE} filled in
  /feeds/<name>.xml                                         a small valid RSS feed titled after <name>
  /missing.xml (404), /error.xml (500), /img/<any> (a small PNG)
Image and fyyd feed URLs are rewritten to this server; combined-search feed URLs keep their example.org
hosts so the displayed order equals the oracle's (it hashes the URLs). Run from the repository root.
"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import struct
import sys
import zlib

PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 18820
BASE = "http://127.0.0.1:%d" % PORT
FIXTURES = Path("TestSupport/Data/add-podcast-discovery")
INPUTS = json.loads((FIXTURES / "discovery-inputs.json").read_text())


def local_images(text):
    return text.replace("https://img.example.org/", BASE + "/img/")


def toplist(country):
    doc = json.loads(json.dumps(INPUTS["toplist"]))
    if country == "DE":
        for i, entry in enumerate(doc["feed"]["entry"], 1):
            entry["im:name"]["label"] = "Deutsch Show %02d" % i
    return local_images(json.dumps(doc))


def lookup_title(identifier):
    for entry in INPUTS["toplist"]["feed"]["entry"]:
        if entry["id"]["attributes"]["im:id"] == identifier:
            return entry["im:name"]["label"].strip()
    return "Lookup " + identifier


def combined(provider):
    case = next(c for c in INPUTS["search"]["combined"] if c["name"] == "small_both")
    return local_images(json.dumps(case[provider]))


def fyyd():
    case = next(c for c in INPUTS["search"]["per_provider"] if c["name"] == "fyyd_only")
    return local_images(json.dumps(case["response"]).replace("https://fyyd.example.de/", BASE + "/feeds/fyyd-"))


def feed(title):
    # An author, so a subscribed top-list feed is excluded from the suggestions (removeSubscribed).
    return ('<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
            '<channel><title>%s</title><itunes:author>Discovery Fixture</itunes:author>'
            '<description>Discovery fixture feed</description><link>%s</link>'
            '<item><guid>%s-1</guid><title>%s episode</title><pubDate>Mon, 01 Jan 2001 01:00:00 GMT</pubDate>'
            '<enclosure url="http://127.0.0.1:18765/30sec.mp3" type="audio/mpeg" length="120000"/></item>'
            '</channel></rss>' % (title, BASE, title, title))


def png():
    raw = b"".join(b"\x00" + b"\x3f\x51\xb5" * 8 for _ in range(8))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def send(self, status, body, mime):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        path, query = url.path, parse_qs(url.query)
        if path.startswith("/apple/") and path.endswith("/rss/toppodcasts/limit=25/explicit=true/json"):
            country = path.split("/")[2]
            if country == "AQ":
                return self.send(400, "{}", "application/json")
            return self.send(200, toplist(country), "application/json")
        if path == "/apple/lookup":
            identifier = query.get("id", [""])[0]
            return self.send(200, json.dumps({"resultCount": 1, "results": [{
                "feedUrl": "%s/feeds/top-%s.xml" % (BASE, identifier), "trackName": lookup_title(identifier),
                "artistName": "Fixture"}]}), "application/json")
        if path == "/apple/search":
            return self.send(200, combined("Apple"), "application/json")
        if path == "/podcastindex/api/1.0/search/byterm":
            if not (self.headers.get("X-Auth-Key") and self.headers.get("X-Auth-Date") and self.headers.get("Authorization")):
                return self.send(401, "{}", "application/json")
            return self.send(200, combined("Podcast Index"), "application/json")
        if path == "/fyyd/0.2/search/podcast":
            return self.send(200, fyyd(), "application/json")
        if path.startswith("/pages/") or path == "/shows/index.html":
            name = "website-relative-links.html" if path == "/shows/index.html" else path[len("/pages/"):]
            page = FIXTURES / "pages" / name
            if "/" in name or not page.is_file():
                return self.send(404, "not found", "text/plain")
            mime = {"html": "text/html", "xml": "application/xml", "json": "application/json",
                    "opml": "text/x-opml", "txt": "text/plain"}[name.rsplit(".", 1)[1]]
            return self.send(200, page.read_text().replace("{BASE}", BASE), mime)
        if path.startswith("/feeds/") and path.endswith(".xml"):
            name = path[len("/feeds/"):-len(".xml")]
            if name.startswith("top-"):
                title = lookup_title(name[len("top-"):])
            else:
                title = {"only": "Only Feed", "mp3": "MP3 Feed", "aac": "AAC Feed", "atom": "Atom Feed",
                         "comments": "Comments Feed", "between": "Between Feed", "before": "Before Feed"}.get(
                    name, "Discovery " + name)
            return self.send(200, feed(title), "application/rss+xml")
        if path == "/missing.xml":
            return self.send(404, "missing", "text/plain")
        if path == "/error.xml":
            return self.send(500, "error", "text/plain")
        if path.startswith("/img/"):
            return self.send(200, png(), "image/png")
        return self.send(404, "not found", "text/plain")

    def log_message(self, format, *args):
        sys.stderr.write("%s\n" % (format % args))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
