"""The app bridge (PROTOCOL §16): the endpoint the Debug app's `-test-hub-bridge <url>` reports to.

From the app (each launch is a session, named by the app):
  POST /bridge/hello {session, pid, library?, clock_offset_ms?, crash_at?}
                                                    a launch, kept with its action clock offset; the hub watches the
                                                    process for its exit
  POST /bridge/events {session, kind, ...}          crash points reached, saves journaled, exports recorded, background
                                                    leases taken, released or expired
  POST /bridge/crash {session, point}               the armed crash point (`-test-sync-crash-at`): logged, then answered
                                                    with the receipt; the app kills itself (SIGKILL) only after it
  GET  /bridge/commands?session=&after=             commands for the app (long poll)
  POST /bridge/commands/<id>/done {ok, result|error}

From the journeys (control API):
  POST /app/command {command, ...}   `expire_lease` (a held lease's production expiration handler),
                                     `run_background_refresh` (the production BGAppRefresh handler) or `run_server_sync`
                                     {work: refresh|processing} (the server library's background task handlers); waits
                                     for the result
  POST /app/kill {pid?}              SIGKILL to the app's process (the latest launch's), its exit confirmed
  POST /app/wait-exit {pid?}         waits until the process has exited

Simulator apps are processes of this Mac, so their exits are watched with kqueue; `exited` is logged with the pid.
"""

from __future__ import annotations

import itertools
import os
import select
import signal
import threading
import time

COMMANDS = {"expire_lease", "run_background_refresh", "run_server_sync"}
EVENT_KINDS = {"crash_point", "save", "export", "lease", "log", "command"}


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class AppBridge:
    def __init__(self, events) -> None:
        self.events = events
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.sessions: dict[str, dict] = {}
        self.latest: str | None = None
        self.commands: list[dict] = []
        self.ids = itertools.count(1)
        self.stopped = False
        self.watchers: list[threading.Thread] = []

    def stop(self) -> None:
        with self.lock:
            self.stopped = True
            self.changed.notify_all()
        for watcher in self.watchers:
            watcher.join(5)
            if watcher.is_alive():
                raise RuntimeError("app process watcher did not exit")

    # ---- from the app

    def hello(self, body: dict) -> dict:
        session, pid = str(body["session"]), int(body["pid"])
        # The action clock offset the launch used (-test-sync-clock-offset-ms), kept as evidence with its session: a JSON
        # integer of milliseconds, nothing converted to one (no fraction, boolean or string).
        offset = body.get("clock_offset_ms")
        if offset is not None and (type(offset) is not int):
            raise ValueError(f"clock_offset_ms must be a JSON integer of milliseconds, not {offset!r}")
        with self.lock:
            self.sessions[session] = {"session": session, "pid": pid, "exited": False, "library": body.get("library"),
                                      "clock_offset_ms": offset, "crash_at": body.get("crash_at")}
            self.latest = session
        event = self.events.emit("app", "hello", session=session, pid=pid, crash_at=body.get("crash_at"),
                                 library=body.get("library"), clock_offset_ms=offset)
        watcher = threading.Thread(target=self._watch, args=(session, pid), daemon=True)
        with self.lock:
            if self.stopped:
                raise RuntimeError("app bridge is shutting down")
            self.watchers.append(watcher)
            watcher.start()
        return {"receipt": event["seq"]}

    def _watch(self, session: str, pid: int) -> None:
        """Logs `exited` once the app's process is gone (kqueue's exit note; a process already gone has no note)."""
        exited = False
        try:
            queue = select.kqueue()
            try:
                queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                             fflags=select.KQ_NOTE_EXIT)], 0)
                while not self.stopped and not exited:
                    exited = bool(queue.control(None, 1, 1.0))
            finally:
                queue.close()
        except ProcessLookupError:
            exited = True
        except OSError:
            pass  # not watchable: checked below
        while not exited and not self.stopped and process_exists(pid):
            time.sleep(0.05)
        if self.stopped:
            return
        with self.lock:
            entry = self.sessions.get(session)
            if entry:
                entry["exited"] = True
            self.changed.notify_all()
        self.events.emit("app", "exited", session=session, pid=pid)

    def report(self, body: dict) -> dict:
        kind = body.get("kind")
        if kind not in EVENT_KINDS:
            raise ValueError(f"kind must be one of {sorted(EVENT_KINDS)}")
        fields = {key: value for key, value in body.items() if key not in ("kind",)}
        event = self.events.emit("app", kind, **fields)
        return {"receipt": event["seq"]}

    def crash(self, body: dict) -> dict:
        """The armed crash point: logged before the answer, so the receipt proves the hub has it."""
        session = str(body["session"])
        with self.lock:
            pid = self.sessions.get(session, {}).get("pid")
        event = self.events.emit("app", "crash_point", session=session, pid=pid, point=body["point"], armed=True,
                                 kill="SIGKILL")
        return {"receipt": event["seq"]}

    def poll(self, session: str, after: int, timeout: float = 20) -> list[dict]:
        deadline = time.monotonic() + timeout
        with self.lock:
            if session in self.sessions:
                self.sessions[session]["polled"] = time.monotonic()
            while True:
                waiting = [command for command in self.commands if command["id"] > after and command["state"] == "queued"
                           and command["session"] in (None, session)]
                if waiting or self.stopped:
                    for command in waiting:
                        command["state"] = "sent"
                        command["session"] = session
                    return [{"id": command["id"], "command": command["command"], "args": command["args"]} for command in waiting]
                left = deadline - time.monotonic()
                if left <= 0:
                    return []
                self.changed.wait(left)

    def done(self, command_id: int, body: dict) -> dict:
        with self.lock:
            for command in self.commands:
                if command["id"] == command_id:
                    command["state"] = "done"
                    command["result"] = body
                    self.changed.notify_all()
                    break
            else:
                raise KeyError(f"no command {command_id}")
        self.events.emit("app", "command", command=command["command"], id=command_id, ok=bool(body.get("ok")),
                         error=body.get("error"), result=body.get("result"))
        return {}

    # ---- from the journeys

    def describe(self) -> dict:
        with self.lock:
            return {"latest": self.latest, "sessions": list(self.sessions.values()),
                    "commands": [{key: value for key, value in command.items()} for command in self.commands[-20:]]}

    def command(self, body: dict) -> dict:
        name = body.get("command")
        if name not in COMMANDS:
            raise ValueError(f"command must be one of {sorted(COMMANDS)}")
        args = {key: value for key, value in body.items() if key not in ("command", "timeout", "session")}
        timeout = float(body.get("timeout", 60))
        with self.lock:
            command = {"id": next(self.ids), "command": name, "args": args, "state": "queued",
                       "session": body.get("session"), "result": None}
            self.commands.append(command)
            self.changed.notify_all()
            deadline = time.monotonic() + timeout
            while command["state"] != "done":
                if self.stopped:
                    raise RuntimeError("app bridge is shutting down")
                left = deadline - time.monotonic()
                if left <= 0:
                    command["state"] = "timed_out"
                    raise TimeoutError(f"the app did not run {name} within {timeout:g} s (no app polling?)")
                self.changed.wait(left)
            return command["result"]

    def _pid(self, body: dict) -> int:
        if body.get("pid"):
            return int(body["pid"])
        with self.lock:
            if body.get("session") and body["session"] in self.sessions:
                return self.sessions[body["session"]]["pid"]
            if self.latest is None:
                raise KeyError("no app has said hello")
            return self.sessions[self.latest]["pid"]

    def kill(self, body: dict) -> dict:
        """The hub kills the app (PROTOCOL §8.2: on the bridge's report of a save after an export), and confirms the exit."""
        pid = self._pid(body)
        self.events.emit("app", "kill", pid=pid, reason=body.get("reason"))
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return self.wait_exit({"pid": pid, "timeout": body.get("timeout", 30)})

    def wait_exit(self, body: dict) -> dict:
        """Waits for the watched process's `exited` event (a process that never said hello is checked directly)."""
        pid = self._pid(body)
        timeout = float(body.get("timeout", 30))
        with self.lock:
            watched = any(entry["pid"] == pid for entry in self.sessions.values())
        if watched:
            exited = self.events.wait(0, {"source": "app", "kind": "exited", "pid": pid}, timeout=timeout)
            if not exited:
                raise TimeoutError(f"process {pid} is still running")
            return {"pid": pid, "exited": True, "event": exited[0]["seq"]}
        deadline = time.monotonic() + timeout
        while process_exists(pid):
            if time.monotonic() > deadline:
                raise TimeoutError(f"process {pid} is still running")
            time.sleep(0.02)
        return {"pid": pid, "exited": True, "event": None}
