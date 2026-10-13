"""The web bridge (PROTOCOL §16): `POST /web/<profile>/<command>` goes to the web actor (the pinned web copy's
`e2e/acceptance/actor.ts`, protocol 1 of its PROTOCOL.md), started on first use; `POST /web/<command>` for the actor's
own commands (`hello`, `profiles`, `shutdown`). The answer is the actor's (`{ok, result}` or `{ok: false, error}`). The
hub checks the protocol with `hello` before anything else and refuses to go on with another version. `open` without
a `base_url` opens the proxy's address, the one browsers use. The actor's diagnostics go to the run's `web/actor.log`.
"""

from __future__ import annotations

import itertools
import json
import os
import select
import subprocess
import threading
import time
import uuid
from pathlib import Path

from .evidence import private_directory
from .processes import finish_process, finish_registered_groups, owned_popen, preflight_registered_groups

PROTOCOL = 1


class WebError(RuntimeError):
    pass


class WebActor:
    def __init__(self, events, candidate, folder: Path, base_url: str) -> None:
        self.events = events
        self.candidate = candidate
        self.folder = folder
        self.base_url = base_url
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.process_lock = threading.Lock()
        self.process: subprocess.Popen | None = None
        self.answers: dict[str, dict] = {}
        self.arrived = threading.Condition()
        self.ids = itertools.count(1)
        self.hello: dict | None = None
        self.reader: threading.Thread | None = None
        self.closing = threading.Event()
        self.stopping = threading.Event()
        self.commands: set[str] = set()
        external = os.environ.get("NTP_FIXTURE_OWNERSHIP_DIR")
        self.ownership = Path(external) / ("web-" + uuid.uuid4().hex) if external else self.folder / "ownership"

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def describe(self) -> dict:
        return {"running": self.running, "hello": self.hello, "web_commit": self.candidate.web_commit}

    def start(self) -> dict:
        with self.lock:
            if self.closing.is_set() or self.stopping.is_set():
                raise WebError("the web actor is shutting down")
            if self.running:
                return self.hello
            copy = self.candidate.web_copy()
            private_directory(self.folder)
            log = open(self.folder / "actor.log", "a")
            os.chmod(self.folder / "actor.log", 0o600)
            try:
                with self.process_lock:
                    if self.closing.is_set() or self.stopping.is_set():
                        raise WebError("the web actor is shutting down")
                    self.process = owned_popen(["node", "--require", str(Path(__file__).with_name("actor-process-ownership.cjs")),
                                               "e2e/acceptance/actor.ts"], cwd=copy, stdin=subprocess.PIPE,
                                              stdout=subprocess.PIPE, stderr=log, bufsize=0,
                                              env=dict(os.environ, NTP_ACTOR_TRACE="1", NTP_FIXTURE_OWNERSHIP_DIR=str(self.ownership.resolve())))
                    os.set_blocking(self.process.stdin.fileno(), False)
            finally:
                log.close()
            self.reader = threading.Thread(target=self._read, args=(self.process,), daemon=True)
            self.reader.start()
            answer = self._call({"cmd": "hello", "args": {"protocol": PROTOCOL}}, timeout=120)
            if not answer.get("ok") or answer["result"].get("protocol") != PROTOCOL:
                self._kill()
                raise WebError(f"the web actor does not speak protocol {PROTOCOL}: {answer}")
            self.hello = answer["result"]
            self.events.emit("web", "started", pid=self.process.pid, protocol=PROTOCOL, app_version=self.hello.get("app_version"))
            return self.hello

    def _read(self, process: subprocess.Popen) -> None:
        for line in process.stdout:
            try:
                answer = json.loads(line)
            except ValueError:
                continue
            with self.arrived:
                self.answers[str(answer.get("id"))] = answer
                self.arrived.notify_all()
        with self.arrived:
            self.arrived.notify_all()

    def _call(self, request: dict, timeout: float) -> dict:
        process = self.process
        if process is None or process.poll() is not None:
            raise WebError("the web actor is not running")
        request_id = f"hub-{next(self.ids)}"
        line = (json.dumps({"id": request_id, **request}) + "\n").encode()
        deadline = time.monotonic() + timeout
        cancel = self.stopping  # One actor generation; a later public restart cannot uncancel this call.
        with self.arrived:
            self.commands.add(request_id)
        try:
            self._write(process, line, min(deadline, time.monotonic() + 20), cancel)
            with self.arrived:
                while request_id not in self.answers:
                    if self.closing.is_set() or cancel.is_set():
                        raise WebError("web actor command cancelled by shutdown")
                    if process.poll() is not None:
                        raise WebError("the web actor exited")
                    left = deadline - time.monotonic()
                    if left <= 0:
                        raise TimeoutError(f"the web actor did not answer {request.get('cmd')} within {timeout:g} s")
                    self.arrived.wait(min(left, 1.0))
                return self.answers.pop(request_id)
        finally:
            with self.arrived:
                self.commands.discard(request_id)
                self.arrived.notify_all()

    def _write(self, process, line: bytes, deadline: float, cancel: threading.Event) -> None:
        # FileIO + nonblocking os.write has no buffered-stream lock for close to deadlock on.
        acquired = False
        try:
            while not acquired:
                if self.closing.is_set() or cancel.is_set():
                    raise WebError("web actor command cancelled by shutdown")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("web actor command write exceeded its 20 s budget")
                acquired = self.write_lock.acquire(timeout=min(left, 0.1))
            descriptor = process.stdin.fileno()
            offset = 0
            while offset < len(line):
                if self.closing.is_set() or cancel.is_set():
                    raise WebError("web actor command cancelled by shutdown")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("web actor command write exceeded its 20 s budget")
                if not select.select([], [descriptor], [], min(left, 0.1))[1]:
                    continue
                try:
                    offset += os.write(descriptor, line[offset:offset + 65536])
                except BlockingIOError:
                    continue
                except BrokenPipeError as error:
                    raise WebError("the web actor stopped reading commands") from error
        finally:
            if acquired:
                self.write_lock.release()

    def call(self, profile: str | None, command: str, args: dict) -> dict:
        self.start()
        args = dict(args)
        if command == "open" and "base_url" not in args:
            args["base_url"] = self.base_url
        request: dict = {"cmd": command, "args": args}
        if profile:
            request["profile"] = profile
        started = time.monotonic()
        # The actor's own deadline (`timeout_ms`, else its default of at most 30 min) ends every command first.
        budget = float(args.get("timeout_ms", 1_800_000)) / 1000 + 60
        answer = self._call(request, timeout=budget)
        error = answer.get("error") or {}
        self.events.emit("web", "command", profile=profile, command=command, ok=answer.get("ok"), code=error.get("code"),
                         ms=int((time.monotonic() - started) * 1000))
        return answer

    def _kill(self) -> None:
        preflight_registered_groups(self.ownership)
        if self.process:
            finish_process(self.process, timeout=0)
        finish_registered_groups(self.ownership, timeout=0)

    def stop(self, terminal: bool = False, timeout: float = 20) -> dict:
        if terminal:
            self.closing.set()
        self.stopping.set()
        with self.arrived:
            self.arrived.notify_all()
        # Startup's hello wait and any pipe write now cancel. If startup itself is stuck, kill/reap
        # the recorded group before waiting for its lock or touching its streams.
        acquired = self.lock.acquire(timeout=5)
        if not acquired:
            with self.process_lock:
                process = self.process
            if process:
                preflight_registered_groups(self.ownership)
                finish_process(process, timeout=0)
            acquired = self.lock.acquire(timeout=5)
        if not acquired:
            raise WebError("web actor startup did not finish during shutdown")
        try:
            if self.process is None:
                detached = finish_registered_groups(self.ownership, timeout=min(timeout, 5))
                if not terminal:
                    self.stopping = threading.Event()
                return {"exited": True, "started": False, "detached_groups": detached}
            writable = self.write_lock.acquire(timeout=5)
            if writable:
                try:
                    preflight_registered_groups(self.ownership)
                    if self.process.stdin and not self.process.stdin.closed:
                        self.process.stdin.close()  # ordinary actor/Chromium EOF shutdown
                finally:
                    self.write_lock.release()
            else:
                preflight_registered_groups(self.ownership)
                finish_process(self.process, timeout=0)  # reap before potentially blocking close/join
            preflight_registered_groups(self.ownership)
            terminal = finish_process(self.process, timeout=timeout, graceful=True)
            terminal["detached_groups"] = finish_registered_groups(self.ownership, timeout=min(timeout, 5))
            with self.arrived:
                if not self.arrived.wait_for(lambda: not self.commands, timeout=5):
                    raise WebError("web actor commands did not cancel during shutdown")
            if not writable and self.process.stdin:
                self.process.stdin.close()
            if self.reader:
                self.reader.join(10)
                if self.reader.is_alive():
                    raise WebError("web actor output reader did not finish")
            if self.process.stdout:
                self.process.stdout.close()
            self.events.emit("web", "stopped", **terminal)
            self.process = None
            self.hello = None
            self.answers.clear()
            if not self.closing.is_set():
                self.stopping = threading.Event()
            return terminal
        finally:
            self.lock.release()
