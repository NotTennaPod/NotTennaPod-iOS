#!/usr/bin/env python3
"""Serve a synthetic Nextcloud Login Flow v2 and gpoddersync provider.

The fixture binds only to 127.0.0.1:18813. Each safe identifier below
``/cloud/<id>`` owns independent Login Flow attempts, retry controls, route
counts, cursors, and captured uploads. The only provider credential is the
synthetic password ``fixture-password``; no request details are logged and
inspection never includes headers, Login Flow tokens, or passwords.

Retry controls are set with ``POST /control/<id>`` and a JSON object containing
any of ``startFailures``, ``pollFailures``, and ``syncFailures``. Each value is
the number of next matching requests that should return HTTP 503 before normal
behavior resumes. Omitted controls keep their current remaining count; setting
one to zero clears it. ``POST /reset/<id>`` clears the whole session, including
all pending authorizations and failure controls.
"""

from __future__ import annotations

import base64
import copy
import hmac
import html
import json
import re
import secrets
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit
from xml.sax.saxutils import escape as xml_escape


HOST = "127.0.0.1"
PORT = 18813
APP_PASSWORD = "fixture-password"
INITIAL_CURSOR = 1_800_000_000
MEDIA_PATH = Path(__file__).resolve().parents[1] / "Media" / "listening" / "sync-60sec.mp3"
SAFE_ID = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\Z")
FAILURE_KEYS = {"startFailures", "pollFailures", "syncFailures"}
SENSITIVE_UPLOAD_KEYS = {"authorization", "password", "apppassword", "token", "accesstoken", "refreshtoken", "secret"}


class LoginAttempt:
    def __init__(self, token: str) -> None:
        self.token = token
        self.granted = False
        self.denied = False


class SessionState:
    def __init__(self) -> None:
        self.auth_start = 0
        self.browser = 0
        self.grant = 0
        self.deny = 0
        self.poll = 0
        self.flows: dict[str, LoginAttempt] = {}
        self.sync_routes: Counter[str] = Counter()
        self.sync_since: list[dict[str, object]] = []
        self.subscription_uploads: list[dict[str, object]] = []
        self.episode_uploads: list[dict[str, object]] = []
        self.failures = {key: 0 for key in FAILURE_KEYS}


LOCK = threading.RLock()
SESSIONS: dict[str, SessionState] = {}


def session_for(identifier: str) -> SessionState:
    with LOCK:
        return SESSIONS.setdefault(identifier, SessionState())


def cloud_root(identifier: str) -> str:
    return f"http://{HOST}:{PORT}/cloud/{identifier}"


def feed_url(identifier: str) -> str:
    return cloud_root(identifier) + "/feed.xml"


def episode_url(identifier: str) -> str:
    return cloud_root(identifier) + "/sync-60sec.mp3"


def feed_document(identifier: str) -> bytes:
    enclosure = episode_url(identifier)
    length = MEDIA_PATH.stat().st_size
    document = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
        '<channel><title>Nextcloud sync fixture</title>'
        f'<link>{xml_escape(feed_url(identifier))}</link>'
        '<description>A synthetic Nextcloud synchronization podcast.</description>'
        '<item><guid isPermaLink="false">sync-episode</guid>'
        '<title>Synced fixture episode</title>'
        '<description>A sixty-second synthetic episode.</description>'
        '<pubDate>Thu, 01 Jan 2026 00:00:00 GMT</pubDate>'
        f'<enclosure url="{xml_escape(enclosure)}" type="audio/mpeg" length="{length}"/>'
        '<itunes:duration>01:00</itunes:duration></item>'
        '</channel></rss>'
    )
    return document.encode("utf-8")


def remote_episode_action(identifier: str) -> dict[str, object]:
    return {
        "podcast": feed_url(identifier),
        "episode": episode_url(identifier),
        "guid": "sync-episode",
        "action": "PLAY",
        "timestamp": "2026-01-01T00:00:00Z",
        "started": 0,
        "position": 12,
        "total": 60,
    }


def safe_upload_value(value: object) -> object:
    """Keep useful upload evidence while omitting credential-shaped values."""
    if isinstance(value, dict):
        result: dict[str, object] = {}
        for key, item in value.items():
            normalized = str(key).replace("_", "").replace("-", "").lower()
            if normalized in SENSITIVE_UPLOAD_KEYS or "password" in normalized or normalized.endswith("token"):
                result[str(key)] = "[redacted]"
            else:
                result[str(key)] = safe_upload_value(item)
        return result
    if isinstance(value, list):
        return [safe_upload_value(item) for item in value]
    if isinstance(value, str):
        try:
            parts = urlsplit(value)
        except ValueError:
            return "[redacted]"
        if parts.scheme and parts.netloc:
            netloc = parts.netloc.rsplit("@", 1)[-1]
            query = [
                (key, "[redacted]" if key.replace("_", "").replace("-", "").lower() in SENSITIVE_UPLOAD_KEYS
                 or "password" in key.lower() or key.lower().endswith("token") else item)
                for key, item in parse_qsl(parts.query, keep_blank_values=True)
            ]
            return urlunsplit((parts.scheme, netloc, parts.path, urlencode(query, doseq=True), parts.fragment))
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        # In particular, never print URLs containing Login Flow state values.
        return

    def log_request(self, _code: int | str = "-", _size: int | str = "-") -> None:
        return

    def log_error(self, _format: str, *_args: object) -> None:
        return

    def do_GET(self) -> None:
        self._dispatch(send_body=True)

    def do_HEAD(self) -> None:
        self._dispatch(send_body=False)

    def do_POST(self) -> None:
        self._dispatch(send_body=True)

    def _dispatch(self, *, send_body: bool) -> None:
        request = urlsplit(self.path)
        decoded = [unquote(part, errors="replace") for part in request.path.strip("/").split("/")]
        if request.path == "/":
            decoded = []

        if len(decoded) == 2 and decoded[0] == "inspect" and self.command == "GET":
            identifier = decoded[1]
            if self._valid_id(identifier):
                self._json(200, self._inspection(identifier))
                return

        if len(decoded) == 2 and decoded[0] == "reset" and self.command == "POST":
            identifier = decoded[1]
            if self._valid_id(identifier):
                self._read_body()
                with LOCK:
                    SESSIONS[identifier] = SessionState()
                self._json(200, {"reset": True})
                return

        if len(decoded) == 2 and decoded[0] == "control" and self.command == "POST":
            identifier = decoded[1]
            if self._valid_id(identifier):
                self._control(identifier)
                return

        if len(decoded) >= 2 and decoded[0] == "cloud" and self._valid_id(decoded[1]):
            identifier = decoded[1]
            tail = decoded[2:]
            if tail == ["index.php", "login", "v2"] and self.command == "POST":
                self._start_login(identifier)
                return
            if tail == ["index.php", "login", "v2", "poll"] and self.command == "POST":
                self._poll_login(identifier)
                return
            if tail == ["login"] and self.command == "GET":
                self._browser_login(identifier, request.query)
                return
            if tail == ["login", "grant"] and self.command == "POST":
                self._browser_decision(identifier, grant=True)
                return
            if tail == ["login", "deny"] and self.command == "POST":
                self._browser_decision(identifier, grant=False)
                return
            if tail == ["feed.xml"] and self.command in ("GET", "HEAD"):
                self._bytes(200, feed_document(identifier), "application/rss+xml; charset=utf-8", send_body=send_body)
                return
            if tail == ["sync-60sec.mp3"] and self.command in ("GET", "HEAD"):
                self._media(send_body=send_body)
                return
            if tail[:3] == ["index.php", "apps", "gpoddersync"]:
                if self._provider_request(identifier, tail[3:], request.query):
                    return

        if self.command == "POST":
            self._read_body()
        self._not_found()

    @staticmethod
    def _valid_id(identifier: str) -> bool:
        return SAFE_ID.fullmatch(identifier) is not None

    def _start_login(self, identifier: str) -> None:
        state = session_for(identifier)
        body = self._read_body()
        with LOCK:
            state.auth_start += 1
            if state.failures["startFailures"] > 0:
                state.failures["startFailures"] -= 1
                should_fail = True
            else:
                should_fail = False
        if should_fail:
            self._json(503, {"error": "Synthetic Login Flow start failure"})
            return
        if body is None or body:
            self._json(400, {"error": "Login Flow start expects an empty form"})
            return

        token = secrets.token_urlsafe(32)
        with LOCK:
            state.flows[token] = LoginAttempt(token)
        root = cloud_root(identifier)
        self._json(200, {
            "login": root + "/login?state=" + quote(token, safe=""),
            "poll": {"token": token, "endpoint": root + "/index.php/login/v2/poll"},
        }, extra={"Cache-Control": "no-store"})

    def _poll_login(self, identifier: str) -> None:
        state = session_for(identifier)
        form = self._read_form()
        token = self._first(form, "token")
        with LOCK:
            state.poll += 1
            if state.failures["pollFailures"] > 0:
                state.failures["pollFailures"] -= 1
                should_fail = True
            else:
                should_fail = False
        if should_fail:
            self._json(503, {"error": "Synthetic Login Flow poll failure"}, extra={"Cache-Control": "no-store"})
            return

        if token is None:
            self._not_found()
            return
        with LOCK:
            attempt = state.flows.get(token)
            granted = attempt is not None and attempt.granted
        if not granted:
            # Denial intentionally remains pending; the source client retries
            # non-200 polls until its own authorization timeout expires.
            self._not_found()
            return
        self._json(200, {
            "server": cloud_root(identifier),
            "loginName": identifier,
            "appPassword": APP_PASSWORD,
        }, extra={"Cache-Control": "no-store"})

    def _browser_login(self, identifier: str, query: str) -> None:
        state = session_for(identifier)
        values = parse_qs(query, keep_blank_values=True)
        token = values.get("state", [""])[-1]
        with LOCK:
            state.browser += 1
            attempt = state.flows.get(token)
        if attempt is None:
            self._not_found()
            return
        escaped_token = html.escape(token, quote=True)
        root = f"/cloud/{identifier}/login"
        page = f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Authorize AntennaPod</title></head>
<body>
<main>
  <h1>Authorize AntennaPod</h1>
  <p>This local Nextcloud fixture is requesting access to the synthetic account <strong>{html.escape(identifier)}</strong>.</p>
  <form action="{root}/grant" method="post">
    <input type="hidden" name="state" value="{escaped_token}">
    <button type="submit" aria-label="Grant access">Grant access</button>
  </form>
  <form action="{root}/deny" method="post">
    <input type="hidden" name="state" value="{escaped_token}">
    <button type="submit" aria-label="Deny access">Deny</button>
  </form>
</main>
</body>
</html>""".encode("utf-8")
        self._bytes(200, page, "text/html; charset=utf-8", send_body=True, extra={"Cache-Control": "no-store"})

    def _browser_decision(self, identifier: str, *, grant: bool) -> None:
        state = session_for(identifier)
        form = self._read_form()
        token = self._first(form, "state")
        with LOCK:
            attempt = state.flows.get(token or "")
            if attempt is not None:
                if grant:
                    attempt.granted = True
                    attempt.denied = False
                    state.grant += 1
                else:
                    attempt.denied = True
                    attempt.granted = False
                    state.deny += 1
        if attempt is None:
            self._not_found()
            return
        if grant:
            heading = "Access granted"
            message = "Authorization is complete. Return to AntennaPod to finish signing in."
        else:
            heading = "Access denied"
            message = "Authorization was denied. You may return to AntennaPod."
        page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{heading}</title></head>
<body><main><h1>{heading}</h1><p>{message}</p></main></body></html>""".encode("utf-8")
        self._bytes(200, page, "text/html; charset=utf-8", send_body=True, extra={"Cache-Control": "no-store"})

    def _control(self, identifier: str) -> None:
        value = self._read_json()
        if not isinstance(value, dict) or any(key not in FAILURE_KEYS for key in value):
            self._json(400, {"error": "Expected startFailures, pollFailures, or syncFailures counts"})
            return
        updates: dict[str, int] = {}
        for key, count in value.items():
            if isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= 100:
                self._json(400, {"error": "Failure counts must be integers from 0 through 100"})
                return
            updates[key] = count
        state = session_for(identifier)
        with LOCK:
            state.failures.update(updates)
            remaining = copy.deepcopy(state.failures)
        self._json(200, {"controls": remaining})

    def _provider_request(self, identifier: str, tail: list[str], query: str) -> bool:
        endpoints: dict[tuple[str, ...], str] = {
            ("subscriptions",): "subscriptions",
            ("subscription_change", "create"): "subscription_change/create",
            ("episode_action",): "episode_action",
            ("episode_action", "create"): "episode_action/create",
        }
        endpoint = endpoints.get(tuple(tail))
        if endpoint is None:
            return False
        expected_method = "GET" if endpoint in ("subscriptions", "episode_action") else "POST"
        if self.command != expected_method:
            return False

        body = self._read_json() if expected_method == "POST" else None
        full_path = urlsplit(self.path).path
        route = f"{self.command} {full_path}"
        state = session_for(identifier)
        since = self._since_value(query) if self.command == "GET" else None
        with LOCK:
            state.sync_routes[route] += 1
            if since is not None:
                state.sync_since.append({"route": full_path, "value": since})
        if not self._authorized_provider(identifier):
            self._unauthorized()
            return True
        with LOCK:
            if state.failures["syncFailures"] > 0:
                state.failures["syncFailures"] -= 1
                should_fail = True
            else:
                should_fail = False
        if should_fail:
            self._json(503, {"error": "Synthetic synchronization failure"})
            return True

        if endpoint == "subscriptions":
            added = [feed_url(identifier)] if since == 0 else []
            self._json(200, {"add": added, "remove": [], "timestamp": INITIAL_CURSOR})
            return True
        if endpoint == "episode_action":
            actions = [remote_episode_action(identifier)] if since == 0 else []
            self._json(200, {"actions": actions, "timestamp": INITIAL_CURSOR})
            return True
        if endpoint == "subscription_change/create":
            if not isinstance(body, dict) or not isinstance(body.get("add"), list) or not isinstance(body.get("remove"), list):
                self._json(400, {"error": "Expected add and remove arrays"})
                return True
            with LOCK:
                state.subscription_uploads.append({
                    "route": full_path,
                    "add": safe_upload_value(body["add"]),
                    "remove": safe_upload_value(body["remove"]),
                })
            self._json(200, {})
            return True
        if endpoint == "episode_action/create":
            if not isinstance(body, list) or not all(isinstance(item, dict) for item in body):
                self._json(400, {"error": "Expected an episode action array"})
                return True
            with LOCK:
                state.episode_uploads.append({"route": full_path, "actions": safe_upload_value(body)})
            self._json(200, {})
            return True
        return False

    def _authorized_provider(self, identifier: str) -> bool:
        expected = "Basic " + base64.b64encode(f"{identifier}:{APP_PASSWORD}".encode("ascii")).decode("ascii")
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)

    @staticmethod
    def _since_value(query: str) -> int:
        values = parse_qs(query, keep_blank_values=True).get("since", [])
        try:
            return int(values[-1]) if values else 0
        except ValueError:
            return -1

    def _inspection(self, identifier: str) -> dict[str, object]:
        state = session_for(identifier)
        with LOCK:
            return {
                "auth_start": state.auth_start,
                "browser": state.browser,
                "grant": state.grant,
                "deny": state.deny,
                "poll": state.poll,
                "sync_routes": dict(state.sync_routes),
                "sync_since": copy.deepcopy(state.sync_since),
                "subscription_uploads": copy.deepcopy(state.subscription_uploads),
                "episode_uploads": copy.deepcopy(state.episode_uploads),
                "controls": copy.deepcopy(state.failures),
            }

    def _read_body(self) -> bytes | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > 1_000_000:
            self.close_connection = True
            return None
        try:
            return self.rfile.read(length)
        except OSError:
            return None

    def _read_form(self) -> dict[str, list[str]] | None:
        body = self._read_body()
        if body is None:
            return None
        try:
            return parse_qs(body.decode("utf-8"), keep_blank_values=True)
        except UnicodeDecodeError:
            return None

    def _read_json(self) -> object | None:
        body = self._read_body()
        if body is None:
            return None
        try:
            return json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    @staticmethod
    def _first(form: dict[str, list[str]] | None, key: str) -> str | None:
        if form is None:
            return None
        values = form.get(key, [])
        return values[-1] if values else None

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

    def _json(self, status: int, value: object, *, extra: dict[str, str] | None = None) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self._bytes(status, body, "application/json; charset=utf-8", send_body=True, extra=extra)

    def _unauthorized(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Nextcloud sync fixture", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _not_found(self) -> None:
        self._bytes(404, b"", "text/plain; charset=utf-8", send_body=False)


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    def handle_error(self, _request: object, _client_address: object) -> None:
        # Keep unexpected request failures from dumping request-adjacent data.
        return


def main() -> None:
    if not MEDIA_PATH.is_file():
        raise SystemExit(f"Fixture media is missing: {MEDIA_PATH}")
    server = QuietThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"Synthetic Nextcloud fixture listening at http://{HOST}:{PORT}")
    print(f"Inspect: http://{HOST}:{PORT}/inspect/<id>   Reset: POST http://{HOST}:{PORT}/reset/<id>")
    print(f"Controls: POST http://{HOST}:{PORT}/control/<id>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
