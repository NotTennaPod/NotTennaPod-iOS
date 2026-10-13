#!/usr/bin/env python3
"""Serve a synthetic, gpodder-compatible synchronization account on loopback.

Run from any directory with Python 3. The fixture binds only to 127.0.0.1:18812
and accepts the fixed password ``fixture-password``. Each username has isolated
devices, cursors, request counts, and upload records. Inspection never includes
request headers, passwords, or session cookies.
"""

from __future__ import annotations

import base64
import copy
import hmac
import json
import secrets
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlsplit


HOST = "127.0.0.1"
PORT = 18812
PASSWORD = "fixture-password"
COOKIE_NAME = "fixture_session"
INITIAL_CURSOR = 1_800_000_000
MEDIA_PATH = Path(__file__).resolve().parents[1] / "Media" / "listening" / "sync-60sec.mp3"


class AccountState:
    def __init__(self) -> None:
        self.devices: dict[str, dict[str, object]] = {
            "fixture-device": {
                "id": "fixture-device",
                "caption": "Existing fixture device",
                "type": "mobile",
                "subscriptions": 1,
            }
        }
        self.selected_device_id: str | None = None
        self.cursor = INITIAL_CURSOR - 1
        self.route_counts: Counter[str] = Counter()
        self.routes: list[dict[str, object]] = []
        self.since_requests: list[dict[str, object]] = []
        self.subscription_uploads: list[dict[str, object]] = []
        self.episode_uploads: list[dict[str, object]] = []


LOCK = threading.RLock()
ACCOUNTS: dict[str, AccountState] = {}
SESSIONS: dict[str, str] = {}


def account_for(username: str) -> AccountState:
    with LOCK:
        return ACCOUNTS.setdefault(username, AccountState())


def feed_url(username: str) -> str:
    return f"http://{HOST}:{PORT}/feeds/{quote(username, safe='')}.xml"


def episode_url(username: str) -> str:
    return f"http://{HOST}:{PORT}/media/{quote(username, safe='')}.mp3"


def feed_document(username: str) -> bytes:
    enclosure = episode_url(username)
    length = MEDIA_PATH.stat().st_size
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
        '<channel><title>Synced fixture podcast</title>'
        f'<link>{feed_url(username)}</link>'
        '<description>A synthetic synchronization fixture.</description>'
        '<item><guid isPermaLink="false">sync-episode</guid>'
        '<title>Synced fixture episode</title>'
        '<description>A sixty-second synthetic episode.</description>'
        '<pubDate>Thu, 01 Jan 2026 00:00:00 GMT</pubDate>'
        f'<enclosure url="{enclosure}" type="audio/mpeg" length="{length}"/>'
        '<itunes:duration>01:00</itunes:duration></item>'
        '</channel></rss>'
    ).encode("utf-8")


def remote_episode_action(username: str) -> dict[str, object]:
    return {
        "podcast": feed_url(username),
        "episode": episode_url(username),
        "guid": "sync-episode",
        "action": "PLAY",
        "timestamp": "2026-01-01T00:00:00Z",
        "started": 0,
        "position": 12,
        "total": 60,
    }


def decode_path_segment(value: str) -> str:
    return unquote(value, errors="replace")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        # Do not print request details. Counts are available through /inspect.
        return

    def do_GET(self) -> None:
        self._dispatch(send_body=True)

    def do_HEAD(self) -> None:
        self._dispatch(send_body=False)

    def do_POST(self) -> None:
        self._dispatch(send_body=True)

    def _dispatch(self, *, send_body: bool) -> None:
        path = urlsplit(self.path).path
        parts = path.strip("/").split("/") if path != "/" else []

        if len(parts) == 2 and parts[0] == "inspect" and self.command == "GET":
            self._json(200, self._inspection(decode_path_segment(parts[1])))
            return

        if len(parts) == 2 and parts[0] == "reset" and self.command == "POST":
            username = decode_path_segment(parts[1])
            self._reset(username)
            self._json(200, {"reset": True, "username": username})
            return

        if len(parts) == 5 and parts[:3] == ["api", "2", "auth"] and parts[4] == "login.json":
            if self.command != "POST":
                self._not_found()
                return
            self._login(decode_path_segment(parts[3]))
            return

        if len(parts) == 4 and parts[:3] == ["api", "2", "devices"] and parts[3].endswith(".json"):
            username = decode_path_segment(parts[3][:-5])
            if self.command != "GET":
                self._not_found()
                return
            self._record(username, path)
            if not self._authorized(username):
                self._unauthorized()
                return
            state = account_for(username)
            with LOCK:
                devices = [copy.deepcopy(device) for device in state.devices.values()]
            self._json(200, devices)
            return

        if len(parts) == 5 and parts[:3] == ["api", "2", "devices"] and parts[4].endswith(".json"):
            username = decode_path_segment(parts[3])
            device_id = decode_path_segment(parts[4][:-5])
            if self.command != "POST":
                self._not_found()
                return
            self._record(username, path)
            if not self._authorized(username):
                self._unauthorized()
                return
            self._configure_device(username, device_id)
            return

        if len(parts) == 5 and parts[:3] == ["api", "2", "subscriptions"] and parts[4].endswith(".json"):
            username = decode_path_segment(parts[3])
            device_id = decode_path_segment(parts[4][:-5])
            if self.command not in ("GET", "POST"):
                self._not_found()
                return
            since = self._since_value()
            self._record(username, path, since=since)
            if not self._authorized(username):
                self._unauthorized()
                return
            state = account_for(username)
            with LOCK:
                state.selected_device_id = device_id
            if self.command == "GET":
                with LOCK:
                    timestamp = self._next_timestamp(state)
                added = [feed_url(username)] if since == 0 else []
                self._json(200, {"add": added, "remove": [], "timestamp": timestamp})
            else:
                self._upload_subscriptions(username, path, device_id)
            return

        if len(parts) == 4 and parts[:3] == ["api", "2", "episodes"] and parts[3].endswith(".json"):
            username = decode_path_segment(parts[3][:-5])
            if self.command not in ("GET", "POST"):
                self._not_found()
                return
            since = self._since_value()
            self._record(username, path, since=since)
            if not self._authorized(username):
                self._unauthorized()
                return
            state = account_for(username)
            if self.command == "GET":
                with LOCK:
                    timestamp = self._next_timestamp(state)
                actions = [remote_episode_action(username)] if since == 0 else []
                self._json(200, {"actions": actions, "timestamp": timestamp})
            else:
                self._upload_episodes(username, path)
            return

        if len(parts) == 2 and parts[0] == "feeds" and parts[1].endswith(".xml") and self.command in ("GET", "HEAD"):
            username = decode_path_segment(parts[1][:-4])
            self._record(username, path)
            self._bytes(200, feed_document(username), "application/rss+xml; charset=utf-8", send_body=send_body)
            return

        if len(parts) == 2 and parts[0] == "media" and parts[1].endswith(".mp3") and self.command in ("GET", "HEAD"):
            username = decode_path_segment(parts[1][:-4])
            self._record(username, path)
            self._media(send_body=send_body)
            return

        self._not_found()

    def _login(self, username: str) -> None:
        self._record(username, urlsplit(self.path).path)
        expected = "Basic " + base64.b64encode(f"{username}:{PASSWORD}".encode("utf-8")).decode("ascii")
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, expected):
            self._unauthorized()
            return
        token = secrets.token_urlsafe(24)
        with LOCK:
            account_for(username)
            SESSIONS[token] = username
        body = b""
        self.send_response(200)
        self.send_header("Set-Cookie", f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Lax")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

    def _authorized(self, username: str) -> bool:
        token = None
        for entry in self.headers.get("Cookie", "").split(";"):
            name, separator, value = entry.strip().partition("=")
            if separator and name == COOKIE_NAME:
                token = value
                break
        if token is None:
            return False
        with LOCK:
            return SESSIONS.get(token) == username

    def _configure_device(self, username: str, device_id: str) -> None:
        body = self._read_json()
        if body is None and self.headers.get("Content-Length", "0") == "0":
            body = {}
        if body is None or not isinstance(body, dict):
            self._json(400, {"error": "Expected a device object"})
            return
        caption = body.get("caption")
        device_type = body.get("type")
        if caption == "Rejected device" or device_id == "Rejected device":
            self._json(500, {"error": "Fixture rejected this device"})
            return
        state = account_for(username)
        with LOCK:
            previous = state.devices.get(device_id, {})
            device = {
                "id": device_id,
                "caption": caption if isinstance(caption, str) else previous.get("caption", device_id),
                "type": device_type if isinstance(device_type, str) else previous.get("type", "mobile"),
                "subscriptions": previous.get("subscriptions", 0),
            }
            state.devices[device_id] = device
            state.selected_device_id = device_id
        self._empty(200)

    def _upload_subscriptions(self, username: str, path: str, device_id: str) -> None:
        body = self._read_json()
        if not isinstance(body, dict) or not isinstance(body.get("add"), list) or not isinstance(body.get("remove"), list):
            self._json(400, {"error": "Expected add and remove arrays"})
            return
        state = account_for(username)
        with LOCK:
            timestamp = self._next_timestamp(state)
            state.subscription_uploads.append({
                "route": path,
                "device": device_id,
                "add": copy.deepcopy(body["add"]),
                "remove": copy.deepcopy(body["remove"]),
                "timestamp": timestamp,
            })
        self._json(200, {"timestamp": timestamp, "update_urls": []})

    def _upload_episodes(self, username: str, path: str) -> None:
        body = self._read_json()
        if not isinstance(body, list) or not all(isinstance(item, dict) for item in body):
            self._json(400, {"error": "Expected an episode action array"})
            return
        state = account_for(username)
        with LOCK:
            timestamp = self._next_timestamp(state)
            state.episode_uploads.append({"route": path, "actions": copy.deepcopy(body), "timestamp": timestamp})
        self._json(200, {"timestamp": timestamp, "update_urls": []})

    def _record(self, username: str, path: str, *, since: int | None = None) -> None:
        state = account_for(username)
        event: dict[str, object] = {"method": self.command, "path": path}
        with LOCK:
            key = f"{self.command} {path}"
            state.route_counts[key] += 1
            if since is not None:
                event["since"] = since
                state.since_requests.append({"route": path, "value": since})
            state.routes.append(event)

    def _since_value(self) -> int:
        values = parse_qs(urlsplit(self.path).query).get("since", [])
        try:
            return int(values[-1]) if values else 0
        except ValueError:
            return -1

    @staticmethod
    def _next_timestamp(state: AccountState) -> int:
        state.cursor = max(state.cursor + 1, INITIAL_CURSOR)
        return state.cursor

    def _inspection(self, username: str) -> dict[str, object]:
        state = account_for(username)
        with LOCK:
            selected = state.devices.get(state.selected_device_id or "")
            return {
                "username": username,
                "counts": {"total": sum(state.route_counts.values()), "by_route": dict(state.route_counts)},
                "routes": copy.deepcopy(state.routes),
                "since": copy.deepcopy(state.since_requests),
                "device_id": state.selected_device_id,
                "device": copy.deepcopy(selected),
                "devices": [copy.deepcopy(device) for device in state.devices.values()],
                "subscription_uploads": copy.deepcopy(state.subscription_uploads),
                "episode_uploads": copy.deepcopy(state.episode_uploads),
            }

    def _reset(self, username: str) -> None:
        with LOCK:
            ACCOUNTS[username] = AccountState()
            for token, owner in list(SESSIONS.items()):
                if owner == username:
                    del SESSIONS[token]

    def _read_json(self) -> object | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > 1_000_000:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _media(self, *, send_body: bool) -> None:
        try:
            data = MEDIA_PATH.read_bytes()
        except OSError:
            self._json(500, {"error": "Fixture media is unavailable"})
            return
        header = self.headers.get("Range")
        if not header:
            self._bytes(200, data, "audio/mpeg", send_body=send_body, extra={"Accept-Ranges": "bytes"})
            return
        if not header.startswith("bytes=") or "," in header:
            self._range_not_satisfiable(len(data))
            return
        start_text, separator, end_text = header[6:].partition("-")
        if not separator:
            self._range_not_satisfiable(len(data))
            return
        try:
            if start_text:
                start = int(start_text)
                end = int(end_text) if end_text else len(data) - 1
            else:
                suffix = int(end_text)
                if suffix <= 0:
                    raise ValueError
                start, end = max(0, len(data) - suffix), len(data) - 1
        except ValueError:
            self._range_not_satisfiable(len(data))
            return
        if start < 0 or start >= len(data) or end < start:
            self._range_not_satisfiable(len(data))
            return
        end = min(end, len(data) - 1)
        body = data[start : end + 1]
        self._bytes(206, body, "audio/mpeg", send_body=send_body, extra={
            "Accept-Ranges": "bytes",
            "Content-Range": f"bytes {start}-{end}/{len(data)}",
        })

    def _range_not_satisfiable(self, size: int) -> None:
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{size}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _bytes(self, status: int, body: bytes, content_type: str, *, send_body: bool,
               extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _json(self, status: int, value: object) -> None:
        self._bytes(status, json.dumps(value, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8", send_body=True)

    def _empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _unauthorized(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Synchronization fixture", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _not_found(self) -> None:
        self._empty(404)


def main() -> None:
    if not MEDIA_PATH.is_file():
        raise SystemExit(f"Fixture media is missing: {MEDIA_PATH}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Synthetic gpodder fixture listening at http://{HOST}:{PORT}")
    print("Password: fixture-password (synthetic accounts are isolated by username)")
    print(f"Inspect: http://{HOST}:{PORT}/inspect/<username>   Reset: POST http://{HOST}:{PORT}/reset/<username>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
