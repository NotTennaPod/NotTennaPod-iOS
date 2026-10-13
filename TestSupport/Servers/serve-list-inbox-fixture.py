#!/usr/bin/env python3
"""Session-isolated staged RSS feed and PCM enclosure for the episode-list (Inbox) actions."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import json
from pathlib import Path
import re
import sys
from threading import Lock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
import wave


BASE_DIR = Path(__file__).resolve().parents[1]
MEDIA_PATH = BASE_DIR / "Media" / "list-inbox" / "episode.wav"
CHANNEL_TITLE = "Inbox action lab"
DATA_BYTES = 120 * 8000 * 1 * 2
MEDIA_BYTES = 44 + DATA_BYTES
UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

stages: dict[str, int] = {}
stages_lock = Lock()


def validate_media(path: Path) -> bytes:
    data = path.read_bytes()
    with wave.open(str(path), "rb") as wav:
        actual = (
            wav.getnchannels(),
            wav.getsampwidth(),
            wav.getframerate(),
            wav.getnframes(),
            wav.getcomptype(),
        )
    expected = (1, 2, 8000, 120 * 8000, "NONE")
    if actual != expected or len(data) != MEDIA_BYTES:
        raise ValueError(
            f"{path} has format {actual} and {len(data)} bytes; "
            f"expected {expected} and {MEDIA_BYTES} bytes"
        )
    return data


def publication_date(episode: int) -> str:
    # Episode number increases with publication time. The existing Inbox sort is
    # newest-first, so stage 1's visible order is episode 2, 1, then 0.
    instant = datetime(2024, 1, 1, episode, 0, 0, tzinfo=timezone.utc)
    return format_datetime(instant, usegmt=True)


def feed_xml(stage: int, media_base_url: str) -> bytes:
    episode_ids = [0] if stage == 0 else [2, 1, 0]
    items = []
    for episode in episode_ids:
        items.append(
            "<item>"
            f"<guid isPermaLink=\"false\">inbox-{episode}</guid>"
            f"<title>Inbox episode {episode}</title>"
            f"<description>Deterministic Inbox action episode {episode}.</description>"
            f"<pubDate>{publication_date(episode)}</pubDate>"
            f"<enclosure url=\"{media_base_url}/media.wav?episode={episode}\" "
            f"length=\"{MEDIA_BYTES}\" type=\"audio/wav\"/>"
            "<itunes:duration>120</itunes:duration>"
            "</item>"
        )
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
        "<channel>"
        f"<title>{CHANNEL_TITLE}</title>"
        "<link>https://example.invalid/inbox-action-lab</link>"
        "<description>Session-isolated staged Inbox action fixture.</description>"
        f"{''.join(items)}"
        "</channel></rss>"
    )
    return xml.encode("utf-8")


def parse_range(value: str, size: int) -> tuple[int, int] | None:
    if not value.startswith("bytes=") or "," in value:
        return None
    spec = value[6:].strip()
    if "-" not in spec:
        return None
    first, last = spec.split("-", 1)
    try:
        if first == "":
            suffix_length = int(last)
            if suffix_length <= 0:
                return None
            start = max(size - suffix_length, 0)
            end = size - 1
        else:
            start = int(first)
            end = size - 1 if last == "" else int(last)
            if start < 0 or end < start or start >= size:
                return None
            end = min(end, size - 1)
    except ValueError:
        return None
    return start, end


class Handler(BaseHTTPRequestHandler):
    server_version = "ListInboxFixture/1.0"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        self.route(send_body=True)

    def do_HEAD(self) -> None:
        self.route(send_body=False)

    def route(self, send_body: bool) -> None:
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        if parsed.path not in ("/feed.xml", "/advance", "/media.wav"):
            self.reply(404, b"not found\n", "text/plain; charset=utf-8", send_body)
            return

        if parsed.path == "/advance":
            if not send_body:
                self.reply(405, b"GET required\n", "text/plain; charset=utf-8", False)
                return
            session = self.session(query, send_body=True)
            if session is None:
                return
            values = query.get("stage", [])
            if len(values) != 1 or values[0] not in ("0", "1"):
                self.reply(400, b"stage must be 0 or 1\n", "text/plain; charset=utf-8")
                return
            stage = int(values[0])
            with stages_lock:
                stages[session] = stage
            self.reply(200, f"{stage}\n".encode(), "text/plain; charset=utf-8")
            self.log_state("advance", session, stage)
            return

        if parsed.path == "/feed.xml":
            session = self.session(query, send_body=send_body)
            if session is None:
                return
            with stages_lock:
                stage = stages.get(session, 0)
            body = feed_xml(stage, self.server.media_base_url)  # type: ignore[attr-defined]
            self.reply(200, body, "application/rss+xml; charset=utf-8", send_body)
            self.log_state("feed", session, stage)
            return

        values = query.get("episode", [])
        if len(values) != 1 or values[0] not in ("0", "1", "2"):
            self.reply(404, b"unknown episode\n", "text/plain; charset=utf-8", send_body)
            return
        try:
            media = self.server.media_bytes  # type: ignore[attr-defined]
        except AttributeError:
            self.reply(500, b"media unavailable\n", "text/plain; charset=utf-8", send_body)
            return
        self.serve_media(media, send_body)

    def session(self, query: dict[str, list[str]], send_body: bool) -> str | None:
        values = query.get("session", [])
        if len(values) != 1 or not UUID_PATTERN.fullmatch(values[0]):
            self.reply(
                400,
                b"session must be a UUID\n",
                "text/plain; charset=utf-8",
                send_body,
            )
            return None
        return values[0].lower()

    def serve_media(self, data: bytes, send_body: bool) -> None:
        range_value = self.headers.get("Range")
        if range_value is None:
            self.reply(
                200,
                data,
                "audio/wav",
                send_body,
                extra_headers={"Accept-Ranges": "bytes"},
            )
            return
        bounds = parse_range(range_value, len(data))
        if bounds is None:
            self.send_response(416)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Range", f"bytes */{len(data)}")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        start, end = bounds
        body = data[start:end + 1]
        self.reply(
            206,
            body,
            "audio/wav",
            send_body,
            extra_headers={
                "Accept-Ranges": "bytes",
                "Content-Range": f"bytes {start}-{end}/{len(data)}",
            },
        )

    def reply(
        self,
        status: int,
        body: bytes,
        content_type: str,
        send_body: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for name, value in extra_headers.items():
                self.send_header(name, value)
        self.end_headers()
        if send_body and body:
            self.wfile.write(body)

    def log_state(self, event: str, session: str, stage: int) -> None:
        sys.stdout.write(
            json.dumps({"event": event, "session": session, "stage": stage}) + "\n"
        )
        sys.stdout.flush()

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stdout.write(json.dumps({"http": fmt % args}) + "\n")
        sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18777)
    parser.add_argument("--media-base-url", default=None)
    args = parser.parse_args()

    media = validate_media(MEDIA_PATH)
    media_base_url = args.media_base_url or f"http://127.0.0.1:{args.port}"
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    server.media_bytes = media  # type: ignore[attr-defined]
    server.media_base_url = media_base_url.rstrip("/")  # type: ignore[attr-defined]
    sys.stdout.write(
        json.dumps(
            {
                "event": "list-inbox-fixture-ready",
                "host": args.host,
                "port": args.port,
                "media_bytes": len(media),
                "media_base_url": server.media_base_url,
            }
        )
        + "\n"
    )
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
