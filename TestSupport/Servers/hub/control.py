"""The hub and its control API (PROTOCOL §16). One JSON API on 127.0.0.1:18831; it answers at once, so the
fixture launcher sees the port while the candidate still builds; `GET /ready` waits until everything runs.

  GET  /ready                          {"server": the proxy's URL, "publisher", "run"} once set up, else 503 {"error"}
  GET  /status                         candidate, server, proxy, publisher, apps, web actor, R clients
  POST /accounts {password, username?, import?}   a fresh account; `import` names an Android database or OPML file
                                       in the repository, imported through the web client's import first
  POST /accounts/<id>/password {password}         the administrator resets an account's password (tokens revoked)

  GET  /events?after=&wait=&count=&<member>=<value>...   the event log; `wait` (seconds) long-polls for `count`
  POST /events/wait {after, filters, count, timeout}      the same, as JSON (404 with `last` when it runs out)
  POST /mark {label}                   an event to wait after

  POST /server/start {clock_offset?} | /server/stop | /server/crash {restart?} | /server/hang | /server/resume
  POST /server/restart {clock_offset?} | /server/clock {offset}
  POST /server/backup {name} | /server/restore {name} | /server/wipe {setup?} | /server/witness

  GET  /proxy | POST /proxy/state {state} | POST /proxy/dead-events {dead}
  POST /proxy/rules {mode, method?, path?, fact_type?, skip?, count?, ...} | /proxy/rules/<id>/disarm
  POST /proxy/rules/clear | /proxy/rules/<id>/release | /proxy/holds/<id>/release {mode}

  GET  /publisher | /publisher/counts | POST /publisher/reset | /publisher/state {state}
  POST /publisher/media {off, status?} | /publisher/refuse {user_agent, what?}
  POST /publisher/feeds/<name>/login {username, password} | /publisher/feeds/<name>/mutate {op, ...}

  /bridge/...                          the app bridge (bridge.py); /app/command, /app/kill, /app/wait-exit
  POST /web/<command> | /web/<profile>/<command> {args} | /web/stop     the web actor (web.py)
  POST /r/<name>/login {username, password} | /r/<name>/pull | /r/<name>/play {episode|title, position_ms?}
  POST /r/<name>/checkpoint {session, position_ms} | /r/<name>/end {session, position_ms, completed}
  GET  /r/<name>                       what R knows (its episodes and queue membership)
  POST /transplant {from, to, library?}    the 2I copy (transplant.py)
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import threading
import traceback
import urllib.error
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from . import transplant
from .bridge import AppBridge
from .candidate import ROOT, Candidate
from .events import EventLog
from .evidence import private_directory, retain, write_private
from .httpserver import OwnedHTTPServer
from .proxy import FaultProxy
from .processes import birth
from .publisher import Publisher
from .server import ServerError, ServerLifecycle
from .web import WebActor, WebError
from .wire import WireClient, WireError


class Hub:
    def __init__(self, run: Path, control_port: int = 18831, proxy_port: int = 18830, server_port: int = 0,
                 publisher_port: int = 18834, keep: bool = False, identity: str = "fixture") -> None:
        self.run = run
        self.keep = keep
        self.identity = identity
        self.stopping = threading.Event()
        self.stop_lock = threading.Lock()
        self.start_thread: threading.Thread | None = None
        self.terminal: dict | None = None
        self.retained: Path | None = None
        private_directory(run)
        self.events = EventLog(run / "events.jsonl")
        self.candidate = Candidate(run / "candidate")
        self.ready = threading.Event()
        self.error: str | None = None
        self.server = ServerLifecycle(self.events, self.candidate, run / "server", port=server_port,
                                      on_change=lambda running, graceful: self.proxy.server_changed(running, graceful))
        self.proxy = FaultProxy(self.events, proxy_port, upstream=self.server.upstream,
                                crash=lambda reason, restart: self.server.crash(reason, restart),
                                hang=lambda reason: self.server.hang(reason))
        self.publisher = Publisher(self.events, publisher_port)
        self.bridge = AppBridge(self.events)
        self.web = WebActor(self.events, self.candidate, run / "web", base_url=f"http://127.0.0.1:{proxy_port}")
        self.clients: dict[str, WireClient] = {}
        try:
            self.control = OwnedHTTPServer(("127.0.0.1", control_port), _handler(self))
        except Exception:
            self.events.close()  # construction has not started any child
            raise
        external = os.environ.get("NTP_FIXTURE_TERMINAL_PATH")
        registry = os.environ.get("NTP_HUB_TERMINAL_REGISTRY")
        self.external_terminal = None
        if external:
            self.external_terminal = Path(external)
        elif registry:
            self.external_terminal = Path(registry) / (uuid.uuid4().hex + ".json")
        try:
            if self.external_terminal:
                private_directory(self.external_terminal.parent)
                write_private(self.external_terminal, {"quiesced": False, "pending": True, "run": str(self.run),
                                                       "supervisor_pid": os.getpid(), "supervisor_birth": birth(os.getpid())})
        except Exception:
            self.control.server_close()
            self.events.close()  # still no child/thread has started
            raise

    @property
    def public(self) -> str:
        return f"http://127.0.0.1:{self.proxy.port}"

    def start(self) -> None:
        """Brings everything up; failures are reported through /ready."""
        try:
            self.start_thread = threading.current_thread()
            if self.stopping.is_set():
                raise RuntimeError("hub startup cancelled by shutdown")
            self.events.emit("hub", "starting", run=str(self.run), **self.candidate.describe())
            self.publisher.start()
            self.proxy.start()
            self.web.base_url = self.public
            self.candidate.binary()
            self.server.start(clock_offset=None, reason="hub start")
            self.events.emit("hub", "ready", server=self.public, publisher=self.publisher.base,
                             binary=str(self.candidate.binary()))
        except Exception as error:
            self.error = str(error)
            self.events.emit("hub", "failed", error=self.error)
        finally:
            self.ready.set()

    def launch(self) -> None:
        """Register the startup thread before it can race with teardown."""
        with self.stop_lock:
            if self.stopping.is_set():
                raise RuntimeError("hub is shutting down")
            self.start_thread = threading.Thread(target=self.start, daemon=True)
            self.start_thread.start()

    def stop(self, primary_error: str | None = None) -> dict:
        """Quiesce, finalize and retain logs; only then remove disposable originals.

        Keep records failures as well as success. Incomplete quiescence or retention leaves the originals
        intact and fails cleanup without replacing an already-recorded startup/test error.
        """
        with self.stop_lock:
            if self.terminal is not None:
                if self.terminal["errors"]:
                    raise RuntimeError("; ".join(self.terminal["errors"]))
                return self.terminal
            self.stopping.set()
            self.server.closing.set()
            self.web.closing.set()
            with self.web.arrived:
                self.web.arrived.notify_all()
            errors, children = [], {}
            self.events.emit("hub", "stopping")
            self.events.interrupt_waits()
            self.ready.set()
            try:
                self.control.begin_quiesce()  # No new handlers; socket reads stop before worker joins.
            except Exception as error:
                errors.append(f"control arrival shutdown: {error}")
            try:
                children["server_jobs"] = self.server.cancel_jobs()
            except Exception as error:
                errors.append(f"server command shutdown: {error}")
            try:
                children["builds"] = self.candidate.shutdown()
            except Exception as error:
                errors.append(f"candidate shutdown: {error}")
            try:
                children["server_process"] = self.server.cancel_process()  # Unblock startup HTTP before its join.
            except Exception as error:
                errors.append(f"server startup cancellation: {error}")
            # Release holds and terminate the actor before joining handlers that may be waiting on them.
            for name, stop in (("bridge", self.bridge.stop), ("proxy", self.proxy.stop),
                               ("publisher", self.publisher.stop), ("web", lambda: self.web.stop(terminal=True))):
                try:
                    children[name] = stop()
                except Exception as error:
                    errors.append(f"{name} shutdown: {error}")
            if self.start_thread and self.start_thread is not threading.current_thread():
                self.start_thread.join(10)
                if self.start_thread.is_alive():
                    errors.append("hub startup thread did not exit")
            for name, stop in (("server", self.server.shutdown), ("control", self.control.quiesce)):
                try:
                    children[name] = stop()
                except Exception as error:
                    errors.append(f"{name} shutdown: {error}")
            terminal = {"quiesced": not errors, "children": children, "errors": errors}
            self.events.emit("hub", "stopped", quiesced=not errors)
            self.events.close()
            original_error = primary_error or self.error
            try:
                self.retained = retain(self.run, ROOT / ".work" / "hub-evidence", self.identity,
                                       self.candidate.describe(), terminal, original_error)
                write_private(self.run / "terminal.json", {**terminal, "retained": str(self.retained),
                                                            "primary_error": original_error})
            except Exception as error:
                errors.append(f"evidence retention: {error}")
                terminal["quiesced"] = False
                try:
                    write_private(self.run / "terminal.json", {**terminal, "primary_error": original_error,
                                                                "retention_failed": True})
                except Exception as receipt_error:
                    errors.append(f"terminal receipt: {receipt_error}")
            self.terminal = terminal
            if errors:
                self._external_terminal(original_error)
                raise RuntimeError("; ".join(errors))
            if not self.keep:
                # Recovery inputs/data are disposable; logs already have an immutable private receipt.
                try:
                    if (self.run / "server").exists():
                        shutil.rmtree(self.run / "server", ignore_errors=False)
                    for path in (self.run / "witness").glob("*/data"):
                        shutil.rmtree(path)
                except Exception as error:
                    errors.append(f"disposable cleanup after retained snapshot: {error}")
                    terminal["quiesced"] = False
                    write_private(self.run / "terminal.json", {**terminal, "retained": str(self.retained),
                                                                "primary_error": original_error})
                    self._external_terminal(original_error)
                    raise
            self._external_terminal(original_error)
            return terminal

    def _external_terminal(self, primary_error: str | None) -> None:
        # The launcher checks this durable handoff and its retained private receipt before unlinking
        # any ownership records. Supervisor exit or port closure alone is insufficient.
        if self.external_terminal:
            write_private(self.external_terminal, {**self.terminal, "retained": str(self.retained) if self.retained else None,
                                       "primary_error": primary_error, "retention_failed": self.retained is None})

    def client(self, name: str) -> WireClient:
        if name not in self.clients:
            self.clients[name] = WireClient(self.events, name, self.public)
        return self.clients[name]

    def status(self) -> dict:
        return {"run": str(self.run), "ready": self.ready.is_set() and self.error is None, "error": self.error,
                "public": self.public, "candidate": self.candidate.describe(), "server": self.server.describe(),
                "proxy": self.proxy.describe(), "publisher": {key: value for key, value in self.publisher.describe().items()
                                                              if key != "feeds"},
                "app": self.bridge.describe(), "web": self.web.describe(),
                "r": {name: client.describe() for name, client in self.clients.items()}, "events": self.events.last}


def _flag(value) -> bool:
    return value if isinstance(value, bool) else str(value).lower() in ("1", "true", "yes")


def _handler(hub: Hub):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args) -> None:
            pass

        def reply(self, status: int, body) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(length) if length else b""
            value = json.loads(data or b"{}")
            if not isinstance(value, dict):
                raise ValueError("the body is a JSON object")
            return value

        def do_GET(self) -> None:
            self.dispatch("GET")

        def do_POST(self) -> None:
            self.dispatch("POST")

        def dispatch(self, method: str) -> None:
            url = urllib.parse.urlsplit(self.path)
            parts = [urllib.parse.unquote(part) for part in url.path.split("/") if part]
            query = {key: values[-1] for key, values in urllib.parse.parse_qs(url.query).items()}
            try:
                body = self.body() if method == "POST" else {}
                status, answer = self.route(method, parts, query, body)
            except KeyError as error:
                status, answer = 404, {"error": str(error).strip("'\"")}
            except (ValueError, TypeError) as error:
                status, answer = 400, {"error": str(error)}
            except (ServerError, WebError, LookupError) as error:
                status, answer = 409, {"error": str(error)}
            except TimeoutError as error:
                status, answer = 408, {"error": str(error)}
            except WireError as error:
                status, answer = 502, {"error": str(error), "status": error.status, "body": error.body}
            except urllib.error.HTTPError as error:
                status, answer = 502, {"error": f"server answered {error.code}"}
            except (OSError, http.client.HTTPException) as error:  # the server went away during the request
                status, answer = 502, {"error": f"{type(error).__name__}: {error}"}
            except Exception as error:  # a fault in the hub
                traceback.print_exc()
                status, answer = 500, {"error": f"{type(error).__name__}: {error}"}
            try:
                self.reply(status, answer)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def wait_ready(self) -> None:
            hub.ready.wait(timeout=900)
            if hub.error or not hub.ready.is_set():
                raise ServerError(hub.error or "the hub is still starting")

        def route(self, method: str, parts: list[str], query: dict, body: dict):
            if hub.stopping.is_set():
                return 503, {"error": "hub is shutting down"}
            head = parts[0] if parts else ""
            if (method, parts) == ("GET", ["ready"]):
                hub.ready.wait(timeout=900)
                if hub.error or not hub.ready.is_set():
                    return 503, {"error": hub.error or "the hub is still starting"}
                return 200, {"server": hub.public, "publisher": hub.publisher.base, "run": str(hub.run)}
            if (method, parts) == ("GET", ["status"]):
                return 200, hub.status()
            if head == "bridge":
                return self.on_bridge(method, parts[1:], query, body)
            if head == "events":
                return self.on_events(method, parts[1:], query, body)
            if (method, parts) == ("POST", ["mark"]):
                return 200, hub.events.emit("journey", "mark", label=body.get("label"))
            if head == "transplant" and method == "POST":
                return 200, transplant.transplant(body["from"], body["to"], body.get("library"))
            if head == "publisher":
                return self.on_publisher(method, parts[1:], body)
            if head == "proxy":
                return self.on_proxy(method, parts[1:], body)
            if head == "app" and method == "POST":
                action = parts[1] if len(parts) > 1 else ""
                if action == "command":
                    return 200, hub.bridge.command(body)
                if action == "kill":
                    return 200, hub.bridge.kill(body)
                if action == "wait-exit":
                    return 200, hub.bridge.wait_exit(body)
            if head == "app" and method == "GET":
                return 200, hub.bridge.describe()
            self.wait_ready()
            if head == "accounts" and method == "POST":
                return self.on_accounts(parts[1:], body)
            if head == "server":
                return self.on_server(method, parts[1:], body)
            if head == "web" and method == "POST":
                if parts[1:] == ["stop"]:
                    hub.web.stop()
                    return 200, {}
                if len(parts) == 2:
                    return 200, hub.web.call(None, parts[1], body)
                if len(parts) == 3:
                    return 200, hub.web.call(parts[1], parts[2], body)
            if head == "r" and len(parts) >= 2:
                return self.on_wire(method, parts[1], parts[2:], body)
            raise KeyError(f"no route {method} /{'/'.join(parts)}")

        def on_events(self, method: str, parts: list[str], query: dict, body: dict):
            if method == "GET" and not parts:
                after = int(query.pop("after", 0))
                wait = float(query.pop("wait", 0))
                count = int(query.pop("count", 1))
                limit = int(query.pop("limit", 0)) or None
                if wait:
                    found = hub.events.wait(after, query, count, wait)
                    if found is None:
                        return 404, {"error": "no such events in time", "last": hub.events.last}
                    return 200, {"events": found, "last": hub.events.last}
                return 200, {"events": hub.events.select(after, query, limit), "last": hub.events.last}
            if method == "POST" and parts == ["wait"]:
                found = hub.events.wait(int(body.get("after", 0)), body.get("filters") or {}, int(body.get("count", 1)),
                                        float(body.get("timeout", 30)))
                if found is None:
                    return 404, {"error": "no such events in time", "last": hub.events.last}
                return 200, {"events": found, "last": hub.events.last}
            raise KeyError("no such events route")

        def on_bridge(self, method: str, parts: list[str], query: dict, body: dict):
            if method == "POST" and parts == ["hello"]:
                return 200, hub.bridge.hello(body)
            if method == "POST" and parts == ["events"]:
                return 200, hub.bridge.report(body)
            if method == "POST" and parts == ["crash"]:
                return 200, hub.bridge.crash(body)
            if method == "GET" and parts == ["commands"]:
                return 200, {"commands": hub.bridge.poll(query.get("session", ""), int(query.get("after", 0)),
                                                         float(query.get("timeout", 20)))}
            if method == "POST" and len(parts) == 3 and parts[0] == "commands" and parts[2] == "done":
                return 200, hub.bridge.done(int(parts[1]), body)
            raise KeyError("no such bridge route")

        def on_accounts(self, parts: list[str], body: dict):
            if not parts:
                result = hub.server.create_account(body["password"], body.get("username"))
                if body.get("import"):
                    path = (ROOT / body["import"]).resolve()
                    if ROOT not in path.parents:
                        raise ValueError("the import must be in the repository")
                    result["import"] = hub.server.import_library(result["username"], body["password"], path)
                return 201, result
            if len(parts) == 2 and parts[1] == "password":
                hub.server.set_password(parts[0], body["password"])
                return 200, {}
            raise KeyError("no such accounts route")

        def on_server(self, method: str, parts: list[str], body: dict):
            server = hub.server
            if method == "GET" and not parts:
                return 200, server.describe()
            if method != "POST" or len(parts) != 1:
                raise KeyError("no such server route")
            action = parts[0]
            if action in ("start", "restart") and any(key in body for key in ("binary", "commit", "candidate", "skew")):
                raise ValueError("the Hub runs only its pinned candidate; alternate server controls are unsupported")
            if action == "start":
                return 200, server.start(clock_offset=body.get("clock_offset", False),
                                         setup=_flag(body.get("setup", True)), reason="hub command")
            if action == "stop":
                return 200, server.stop(reason=body.get("reason", "hub command"))
            if action == "crash":
                server.crash(reason=body.get("reason", "hub command"), restart=_flag(body.get("restart", True)))
                if _flag(body.get("restart", True)) and _flag(body.get("wait", True)):
                    server.await_restart()
                return 200, server.describe()
            if action == "hang":
                return 200, server.hang(reason=body.get("reason", "hub command"))
            if action == "resume":
                return 200, server.resume()
            if action == "restart":
                return 200, server.restart(clock_offset=body.get("clock_offset", False))
            if action == "clock":
                hub.events.emit("server", "clock", offset=body.get("offset"))
                return 200, server.restart(clock_offset=body.get("offset"))
            if action == "backup":
                return 200, server.backup(body["name"])
            if action == "restore":
                return 200, server.restore(body["name"])
            if action == "wipe":
                return 200, server.wipe(setup=_flag(body.get("setup", True)))
            if action == "witness":
                return 200, server.witness(hub.run / "witness")
            raise KeyError(f"no server action {action}")

        def on_proxy(self, method: str, parts: list[str], body: dict):
            proxy = hub.proxy
            if method == "GET" and not parts:
                return 200, proxy.describe()
            if method != "POST":
                raise KeyError("no such proxy route")
            if parts == ["state"]:
                proxy.set_state(body["state"])
                return 200, proxy.describe()
            if parts == ["dead-events"]:
                proxy.set_dead_events(_flag(body.get("dead", True)))
                return 200, proxy.describe()
            if parts == ["rules"]:
                return 200, proxy.arm(body)
            if parts == ["rules", "clear"]:
                return 200, {"disarmed": proxy.disarm(None)}
            if len(parts) == 3 and parts[0] == "rules" and parts[2] == "disarm":
                return 200, {"disarmed": proxy.disarm(int(parts[1]))}
            if len(parts) == 3 and parts[0] == "rules" and parts[2] == "release":
                return 200, proxy.release_rule(int(parts[1]))
            if len(parts) == 3 and parts[0] == "holds" and parts[2] == "release":
                return 200, proxy.release(int(parts[1]), body.get("mode", "continue"))
            raise KeyError("no such proxy route")

        def on_publisher(self, method: str, parts: list[str], body: dict):
            publisher = hub.publisher
            if method == "GET" and not parts:
                return 200, publisher.describe()
            if method == "GET" and parts == ["counts"]:
                return 200, publisher.count_report()
            if method != "POST":
                raise KeyError("no such publisher route")
            if parts == ["reset"]:
                publisher.reset()
                return 200, publisher.describe()
            if parts == ["state"]:
                publisher.set_state(body["state"])
                return 200, {"state": body["state"]}
            if parts == ["media"]:
                publisher.set_media_off(_flag(body.get("off", True)), int(body.get("status", 404)))
                return 200, {}
            if parts == ["refuse"]:
                publisher.refuse_agent(body.get("user_agent"), body.get("what", "feeds"))
                return 200, {}
            if len(parts) == 3 and parts[0] == "feeds" and parts[2] == "login":
                publisher.set_login(parts[1], body["username"], body["password"])
                return 200, {}
            if len(parts) == 3 and parts[0] == "feeds" and parts[2] == "mutate":
                return 200, publisher.mutate(parts[1], body)
            raise KeyError("no such publisher route")

        def on_wire(self, method: str, name: str, parts: list[str], body: dict):
            client = hub.client(name)
            if method == "GET" and not parts:
                return 200, {**client.describe(), "episodes": client.episodes()}
            if method != "POST" or len(parts) != 1:
                raise KeyError("no such R route")
            action = parts[0]
            if action == "login":
                return 200, client.login(body["username"], body["password"], body.get("capabilities"))
            if action == "pull":
                return 200, {"commits": client.pull(), "episodes": client.episodes()}
            if action == "play":
                episode = client.find(body.get("episode"), body.get("title"))
                return 200, client.play(episode, int(body.get("position_ms", 0)))
            if action == "checkpoint":
                return 200, client.checkpoint(body["session"], int(body["position_ms"]))
            if action == "end":
                return 200, client.end(body["session"], int(body["position_ms"]), _flag(body.get("completed", True)))
            if action == "clock":
                client.clock_offset_ms = int(body.get("offset_ms", 0))
                return 200, client.describe()
            raise KeyError(f"no R action {action}")

    return Handler
