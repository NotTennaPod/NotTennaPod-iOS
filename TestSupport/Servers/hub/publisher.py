"""The loopback publisher, Pub (PROTOCOL §16): the catalogue's feeds (`publisher.json`) over repository media,
on its own port; the server reaches it through `--dev-allow-loopback-feeds`, the Simulator directly.

  GET /feeds/<name>.xml          a feed (RSS 2.0 with iTunes tags); ETag and If-None-Match
  GET /media/<feed>/<n>/<m>.mp3  an episode's enclosure: strong ETag, Range (206), If-Range, HEAD

A feed with `auth` accepts only its current login (Basic), for the feed and its media; the login can be changed.
Mutations (`mutate`): new_item, backfill, gain_enclosure, change_guids, reuse_guid, edit_item, remove_item,
set_title, move (301 to a new address). Faults: media off (404, or another status), refusing requests whose
User-Agent contains a string (the server's fetches: "NotTennaPod-Server"), and the whole publisher refusing
connections or accepting them and answering nothing; an outage reaches every request, on connections a client
opened before it too (refusing closes them). Requests are counted by path and by who asked (server, app,
other); every request is an event. Credentials are never logged.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import select
import socket
import struct
import threading
import time
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

from .httpserver import OwnedHTTPServer

ROOT = Path(__file__).resolve().parents[3]
CATALOGUE = Path(__file__).with_name("publisher.json")
STATES = {"pass", "refuse", "silent"}
DAY = 86400

# MPEG audio frame lengths (Layer III only: the repository's media are MP3).
_BITRATES = {1: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
             2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]}
_RATES = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}


def mp3_frames(data: bytes) -> list[bytes]:
    """The MPEG audio frames of an MP3, without its ID3 tags."""
    position = 0
    if data[:3] == b"ID3":
        size = (data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9]
        position = 10 + size + (10 if data[5] & 0x10 else 0)
    end = len(data) - (128 if data[-128:-125] == b"TAG" else 0)
    frames = []
    while position + 4 <= end:
        b1, b2 = data[position + 1], data[position + 2]
        if data[position] != 0xFF or (b1 & 0xE0) != 0xE0:
            raise ValueError(f"no MPEG frame at byte {position}")
        version, layer = (b1 >> 3) & 3, (b1 >> 1) & 3
        if layer != 1 or version == 1:
            raise ValueError("only MPEG Layer III is supported")
        bitrate = _BITRATES[1 if version == 3 else 2][b2 >> 4] * 1000
        rate = _RATES[version][(b2 >> 2) & 3]
        length = (144 if version == 3 else 72) * bitrate // rate + ((b2 >> 1) & 1)
        frames.append(data[position:position + length])
        position += length
    return frames


def repeated_mp3(data: bytes, repeat: int) -> bytes:
    """The audio frames repeated `repeat` times, without the Xing/Info frame (whose frame count would be wrong)."""
    frames = mp3_frames(data)
    if frames and (b"Xing" in frames[0][:64] or b"Info" in frames[0][:64]):
        frames = frames[1:]
    return b"".join(frames) * repeat


class Media:
    def __init__(self, name: str, spec: dict) -> None:
        source = (ROOT / spec["file"]).read_bytes()
        self.name = name
        self.data = repeated_mp3(source, spec["repeat"]) if spec.get("repeat") else source
        self.seconds = int(spec["seconds"])
        self.etag = '"' + hashlib.sha256(self.data).hexdigest()[:32] + '"'


def _reset(connection: socket.socket) -> None:
    try:
        connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def _gone(connection: socket.socket) -> bool:
    """Whether the client of a silenced connection (never answered) closed or reset it. What it sent meanwhile is read
    and dropped, so a close behind a request is seen too."""
    try:
        while select.select([connection], [], [], 0)[0]:
            if not connection.recv(65536):
                return True
        return False
    except (OSError, ValueError):
        return True


def who(user_agent: str) -> str:
    if "NotTennaPod-Server" in user_agent:
        return "server"
    if user_agent.startswith("NotTennaPod/") or "CFNetwork" in user_agent or "AppleCoreMedia" in user_agent:
        return "app"
    return "other"


class Publisher:
    def __init__(self, events, port: int = 0, catalogue: Path = CATALOGUE) -> None:
        self.events = events
        self.port = port
        self.lock = threading.RLock()
        self.lifecycle_lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        spec = json.loads(catalogue.read_text())
        self.media = {name: Media(name, media) for name, media in spec["media"].items()}
        self.original = self._feeds(spec["feeds"])
        self.feeds = copy.deepcopy(self.original)
        self.state = "pass"
        self.media_off: int | None = None
        self.refused_agent: str | None = None
        self.refused_what = "feeds"
        self.counts: dict[str, dict[str, int]] = {}
        self.server: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None
        self.stopped = False
        self.connections: set[socket.socket] = set()

    @staticmethod
    def _feeds(spec: dict) -> dict:
        feeds = {}
        for name, feed in spec.items():
            items = [dict(item) for item in feed.get("items", [])]
            generate = feed.get("generate")
            if generate:
                items = [{"guid": f"hub-{name}-{n}", "title": f"{feed['title']} {n}", "media": generate["media"],
                          "date": generate["first_date"] + (n - 1) * generate["step"]} for n in range(1, generate["count"] + 1)]
            for number, item in enumerate(items, 1):
                item["key"] = number
            feeds[name] = {"title": feed["title"], "description": feed.get("description", ""), "items": items,
                           "auth": dict(feed["auth"]) if feed.get("auth") else None, "path": f"/feeds/{name}.xml",
                           "moved": [], "revision": 1, "next_key": len(items) + 1}
        return feeds

    # ---- lifecycle

    def start(self) -> None:
        self._listen()

    def _listen(self) -> None:
        with self.lifecycle_lock:
            if self.stopped or self.server is not None:
                return
            self._listen_locked()

    def _listen_locked(self) -> None:
        publisher = self

        class Server(OwnedHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(("127.0.0.1", self.port), _handler(publisher))
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self.thread.start()

    def _close(self) -> None:
        with self.lifecycle_lock:
            if self.server:
                self.server.quiesce()
                self.thread.join(10)
                if self.thread.is_alive():
                    raise RuntimeError("publisher listener thread did not exit")
                self.server = None

    def stop(self) -> None:
        with self.lifecycle_lock:
            with self.lock:
                self.stopped = True
                self.changed.notify_all()
            self._close()

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    # ---- control

    def describe(self) -> dict:
        with self.lock:
            return {"base": self.base, "state": self.state, "media_off": self.media_off,
                    "refused_user_agent": self.refused_agent, "refused": self.refused_what if self.refused_agent else None,
                    "media": {name: {"seconds": media.seconds, "bytes": len(media.data), "etag": media.etag}
                              for name, media in self.media.items()},
                    "feeds": {name: self._describe_feed(name) for name in self.feeds}}

    def _describe_feed(self, name: str) -> dict:
        feed = self.feeds[name]
        return {"url": self.base + feed["path"], "title": feed["title"], "private": feed["auth"] is not None,
                "moved_from": [self.base + path for path in feed["moved"]],
                "items": [{"guid": item["guid"], "title": item["title"], "date": item["date"],
                           "media": item.get("media"), "url": self._media_url(name, item) if item.get("media") else None,
                           "seconds": self.media[item["media"]].seconds if item.get("media") else None}
                          for item in feed["items"]]}

    def _media_url(self, feed: str, item: dict) -> str:
        return f"{self.base}/media/{feed}/{item['key']}/{item['media']}.mp3"

    def reset(self) -> None:
        with self.lock:
            self.feeds = copy.deepcopy(self.original)
            self.state, self.media_off, self.refused_agent, self.refused_what = "pass", None, None, "feeds"
            self.counts.clear()
            self.changed.notify_all()
        self.events.emit("publisher", "reset")

    def set_state(self, state: str) -> None:
        with self.lifecycle_lock:
            if self.stopped:
                raise RuntimeError("publisher is shutting down")
            self._set_state_locked(state)

    def _set_state_locked(self, state: str) -> None:
        if state not in STATES:
            raise ValueError(f"state must be one of {sorted(STATES)}")
        with self.lock:
            previous, self.state = self.state, state
            self.changed.notify_all()
        if state == "refuse":
            if self.server:
                self._close()
            # A stopped publisher's connections end too, the ones a client keeps for its next request included.
            with self.lock:
                connections = list(self.connections)
            for connection in connections:
                _reset(connection)
        elif self.server is None:
            self._listen()
        self.events.emit("publisher", "state", state=state, previous=previous)

    def set_media_off(self, off: bool, status: int = 404) -> None:
        with self.lock:
            self.media_off = status if off else None
        self.events.emit("publisher", "media", off=off, status=status if off else None)

    def refuse_agent(self, agent: str | None, what: str = "feeds") -> None:
        if what not in ("feeds", "media", "all"):
            raise ValueError("what is feeds, media or all")
        with self.lock:
            self.refused_agent, self.refused_what = agent or None, what
        self.events.emit("publisher", "refuse", user_agent=agent or None, what=what if agent else None)

    def set_login(self, name: str, username: str, password: str) -> None:
        with self.lock:
            feed = self._feed(name)
            if feed["auth"] is None:
                raise ValueError(f"feed {name} is public")
            feed["auth"] = {"username": username, "password": password}
        self.events.emit("publisher", "login", feed=name)

    def count_report(self) -> dict:
        with self.lock:
            return copy.deepcopy(self.counts)

    def _feed(self, name: str) -> dict:
        if name not in self.feeds:
            raise KeyError(f"no feed {name}")
        return self.feeds[name]

    def mutate(self, name: str, spec: dict) -> dict:
        op = spec.get("op")
        with self.lock:
            feed = self._feed(name)
            items = feed["items"]

            def find(guid: str) -> dict:
                for item in items:
                    if item["guid"] == guid:
                        return item
                raise KeyError(f"no item {guid} in {name}")

            def media(value):
                if value is not None and value not in self.media:
                    raise KeyError(f"no media {value}")
                return value

            def new(guid: str, date: int) -> dict:
                item = {"key": feed["next_key"], "guid": guid, "title": spec.get("title") or f"{feed['title']} {feed['next_key']}",
                        "date": int(date), "media": media(spec.get("media", "tone-8"))}
                feed["next_key"] += 1
                return item

            dates = [item["date"] for item in items] or [int(time.time())]
            if op == "new_item":
                item = new(spec.get("guid") or f"hub-{name}-new-{feed['next_key']}", spec.get("date") or max(dates) + DAY)
                items.append(item)
            elif op == "backfill":
                item = new(spec.get("guid") or f"hub-{name}-old-{feed['next_key']}", spec.get("date") or min(dates) - DAY)
                items.append(item)
            elif op == "gain_enclosure":
                item = find(spec["guid"])
                item["media"] = media(spec.get("media", "tone-8"))
            elif op == "remove_enclosure":
                find(spec["guid"])["media"] = None
            elif op == "change_guids":
                suffix = spec.get("suffix", "-changed")
                for item in items:
                    if not spec.get("guids") or item["guid"] in spec["guids"]:
                        item["guid"] += suffix
            elif op == "reuse_guid":
                old = find(spec["guid"])
                if spec.get("replace", True):
                    items.remove(old)
                items.append(new(spec["guid"], spec.get("date") or max(dates) + DAY))
            elif op == "edit_item":
                item = find(spec["guid"])
                for key in ("title", "date"):
                    if key in spec:
                        item[key] = spec[key]
                if "media" in spec:
                    item["media"] = media(spec["media"])
            elif op == "remove_item":
                items.remove(find(spec["guid"]))
            elif op == "set_title":
                feed["title"] = spec["title"]
            elif op == "move":
                feed["moved"].append(feed["path"])
                feed["path"] = f"/feeds/{name}-moved-{len(feed['moved'])}.xml"
            else:
                raise ValueError("op is new_item, backfill, gain_enclosure, remove_enclosure, change_guids, reuse_guid, "
                                 "edit_item, remove_item, set_title or move")
            feed["revision"] += 1
            described = self._describe_feed(name)
        self.events.emit("publisher", "mutated", feed=name, op=op, revision=feed["revision"])
        return described

    # ---- serving

    def render(self, name: str) -> bytes:
        feed = self.feeds[name]
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">', "<channel>",
               f"<title>{escape(feed['title'])}</title>", f"<link>{escape(self.base)}/</link>",
               f"<description>{escape(feed['description'])}</description>", "<language>en</language>"]
        for item in sorted(feed["items"], key=lambda item: -item["date"]):
            out += ["<item>", f'<guid isPermaLink="false">{escape(item["guid"])}</guid>', f"<title>{escape(item['title'])}</title>",
                    f"<pubDate>{formatdate(item['date'], usegmt=True)}</pubDate>",
                    f"<description>{escape(item['title'])} from the hub publisher.</description>"]
            if item.get("media"):
                media = self.media[item["media"]]
                out += [f"<enclosure url={quoteattr(self._media_url(name, item))} length=\"{len(media.data)}\" type=\"audio/mpeg\"/>",
                        f"<itunes:duration>{media.seconds}</itunes:duration>"]
            out.append("</item>")
        out += ["</channel>", "</rss>"]
        return "\n".join(out).encode()

    def count(self, kind: str, path: str, agent: str) -> None:
        with self.lock:
            entry = self.counts.setdefault(path, {"kind": kind, "server": 0, "app": 0, "other": 0, "total": 0})
            entry[agent] += 1
            entry["total"] += 1


def _handler(publisher: Publisher):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args) -> None:
            pass

        def setup(self) -> None:
            super().setup()
            with publisher.lock:
                publisher.connections.add(self.connection)

        def finish(self) -> None:
            with publisher.lock:
                publisher.connections.discard(self.connection)
            super().finish()

        def outage(self) -> str | None:
            """Every request, also on a connection opened before an outage, meets it: silence until the publisher is
            back (then the connection ends unanswered), or a closed connection while it refuses."""
            with publisher.lock:
                state = publisher.state
                if state == "silent":
                    # Connected clients get silence; one that goes away is let go at once.
                    while publisher.state == "silent" and not publisher.stopped and not _gone(self.connection):
                        publisher.changed.wait(0.1)
            if state == "pass":
                return None
            self.close_connection = True
            _reset(self.connection)
            return state

        def handle(self) -> None:
            with publisher.lock:
                silent = publisher.state == "silent"
            if silent:  # accepted, never answered, until the publisher is back or the client goes away
                with publisher.lock:
                    while publisher.state == "silent" and not publisher.stopped and not _gone(self.connection):
                        publisher.changed.wait(0.1)
                _reset(self.connection)
                return
            super().handle()

        def do_HEAD(self) -> None:
            self.serve(body=False)

        def do_GET(self) -> None:
            self.serve(body=True)

        def send(self, status: int, headers: dict, data: bytes = b"", body: bool = True) -> None:
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if body and data:
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def authorized(self, feed: dict) -> str:
            auth = feed["auth"]
            if auth is None:
                return "public"
            header = self.headers.get("Authorization") or ""
            if not header.startswith("Basic "):
                return "missing"
            try:
                username, _, password = base64.b64decode(header[6:]).decode().partition(":")
            except (ValueError, UnicodeDecodeError):
                return "wrong"
            return "ok" if (username, password) == (auth["username"], auth["password"]) else "wrong"

        def serve(self, body: bool) -> None:
            path = self.path.split("?", 1)[0]
            agent = who(self.headers.get("User-Agent") or "")
            fields: dict = {"method": self.command, "path": path, "agent": agent}
            outage = self.outage()
            if outage:
                publisher.events.emit("publisher", "request", status=None, outage=outage, **fields)
                return
            try:
                status = self.route(path, agent, body, fields)
            except (BrokenPipeError, ConnectionResetError):
                status = None
            publisher.events.emit("publisher", "request", status=status, **fields)

        def route(self, path: str, agent: str, body: bool, fields: dict) -> int:
            with publisher.lock:
                refused = publisher.refused_agent and publisher.refused_agent in (self.headers.get("User-Agent") or "")
                what = publisher.refused_what
                feeds = publisher.feeds
                moved = {old: name for name, feed in feeds.items() for old in feed["moved"]}
                current = {feed["path"]: name for name, feed in feeds.items()}
            if path in moved:
                publisher.count("feed", path, agent)
                location = publisher.base + feeds[moved[path]]["path"]
                self.send(301, {"Location": location}, b"", body)
                return 301
            if path in current:
                name = current[path]
                publisher.count("feed", path, agent)
                if refused and what in ("feeds", "all"):
                    self.send(403, {"Content-Type": "text/plain"}, b"Forbidden\n", body)
                    fields["refused"] = True
                    return 403
                with publisher.lock:
                    feed = feeds[name]
                    access = self.authorized(feed)
                    fields["auth"] = access if access != "public" else None
                    if access in ("missing", "wrong"):
                        self.send(401, {"WWW-Authenticate": 'Basic realm="Hub Private"', "Content-Type": "text/plain"},
                                  b"Unauthorized\n", body)
                        return 401
                    data = publisher.render(name)
                    etag = '"feed-%s-%d-%s"' % (name, feed["revision"], hashlib.sha256(data).hexdigest()[:12])
                if self.headers.get("If-None-Match") == etag:
                    self.send(304, {"ETag": etag}, b"", False)
                    return 304
                self.send(200, {"Content-Type": "application/rss+xml; charset=utf-8", "ETag": etag}, data, body)
                return 200
            parts = path.strip("/").split("/")
            if len(parts) == 4 and parts[0] == "media" and parts[1] in feeds and parts[3].endswith(".mp3"):
                return self.media(parts, path, agent, body, refused and what in ("media", "all"), fields)
            self.send(404, {"Content-Type": "text/plain"}, b"Not found\n", body)
            return 404

        def media(self, parts: list[str], path: str, agent: str, body: bool, refused: bool, fields: dict) -> int:
            publisher.count("media", path, agent)
            name, key, media_name = parts[1], parts[2], parts[3][:-4]
            with publisher.lock:
                feed = publisher.feeds[name]
                known = any(str(item["key"]) == key and item.get("media") == media_name for item in feed["items"])
                media = publisher.media.get(media_name)
                off = publisher.media_off
                access = self.authorized(feed)
            if refused:
                self.send(403, {"Content-Type": "text/plain"}, b"Forbidden\n", body)
                return 403
            if access in ("missing", "wrong"):
                fields["auth"] = access
                self.send(401, {"WWW-Authenticate": 'Basic realm="Hub Private"', "Content-Type": "text/plain"},
                          b"Unauthorized\n", body)
                return 401
            if not known or media is None:
                self.send(404, {"Content-Type": "text/plain"}, b"Not found\n", body)
                return 404
            if off is not None:
                fields["media_off"] = True
                self.send(off, {"Content-Type": "text/plain"}, b"Media off\n", body)
                return off
            data, size = media.data, len(media.data)
            headers = {"Content-Type": "audio/mpeg", "Accept-Ranges": "bytes", "ETag": media.etag,
                       "Last-Modified": formatdate(1767225600, usegmt=True)}
            wanted = self.headers.get("Range")
            if_range = self.headers.get("If-Range")
            if wanted and (if_range is None or if_range == media.etag):
                span = self.span(wanted, size)
                if span is None:
                    self.send(416, {"Content-Range": f"bytes */{size}", "ETag": media.etag}, b"", body)
                    return 416
                start, end = span
                fields["range"] = f"{start}-{end}"
                headers["Content-Range"] = f"bytes {start}-{end}/{size}"
                self.send(206, headers, data[start:end + 1], body)
                return 206
            self.send(200, headers, data, body)
            return 200

        @staticmethod
        def span(header: str, size: int) -> tuple[int, int] | None:
            if not header.startswith("bytes=") or "," in header:
                return None
            first, _, last = header[6:].strip().partition("-")
            try:
                if first == "":
                    count = int(last)
                    return (max(0, size - count), size - 1) if count > 0 else None
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            except ValueError:
                return None
            return (start, end) if start <= end and start < size else None

    return Handler
