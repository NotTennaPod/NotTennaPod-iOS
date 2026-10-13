"""The server's lifecycle (PROTOCOL §16): the release candidate on a private loopback port with
`--dev-allow-loopback-feeds`, its data directory in the run's folder, set up with an administrator. Every change is an
event in the log, the clock offset included (the run's artifacts).

  start [clock_offset]                     start the pinned candidate on the same data directory
  stop                                      SIGTERM, then the exit is awaited (a clean stop: an update, `service stop`)
  crash [restart]                           SIGKILL, the exit confirmed; restarted on the same data unless told not to
  hang / resume                             SIGSTOP / SIGCONT, requests and the event stream staying open
  backup <name> / restore <name>            the administrator's online backup, kept under a name; a restore stops the
                                            server, runs `restore` with the key bundle and starts it again
  wipe [setup]                              stop, delete the data directory, start empty (set up unless told not to)
  witness                                   stop, copy the data directory, `make acceptance-witness DATA=<copy>` from
                                            the candidate's archived source, start again
The key bundle is exported once per data directory, right after setup, while nothing else runs.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Callable

from .evidence import private_directory
from .processes import finish_process, owned_popen

ADMIN = ("owner", "owner-fixture-password")


def free_port() -> int:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class ServerError(RuntimeError):
    pass


class ServerLifecycle:
    def __init__(self, events, candidate, folder: Path, port: int = 0, refresh_interval: str = "24h",
                 on_change: Callable[[bool, bool], None] | None = None) -> None:
        self.events = events
        self.candidate = candidate
        self.folder = folder
        self.data = folder / "data"
        self.backups = folder / "backups"
        self.keys = folder / "keys.bundle"
        self.passphrase = folder / "passphrase"
        self.log_path = folder / "server.log"
        self.port = port or free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.refresh_interval = refresh_interval
        self.on_change = on_change or (lambda running, graceful: None)
        self.lock = threading.RLock()
        self.process: subprocess.Popen | None = None
        self.binary: Path | None = None
        self.commit: str | None = None
        self.clock_offset: str | None = None
        self.hung = False
        self.cookie: str | None = None
        self.names: dict[str, str] = {}
        self.witnesses = 0
        self.restarting: threading.Thread | None = None
        self.closing = threading.Event()
        self.job_lock = threading.Lock()
        self.process_lock = threading.Lock()
        self.jobs: set[subprocess.Popen] = set()

    # ---- state

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def upstream(self) -> int | None:
        """The private port while a server process exists (also while it is hung)."""
        return self.port if self.running else None

    def describe(self) -> dict:
        return {"base": self.base, "state": "hung" if self.hung else "running" if self.running else "stopped",
                "pid": self.process.pid if self.running else None, "commit": self.commit,
                "binary": str(self.binary) if self.binary else None, "clock_offset": self.clock_offset,
                "data": str(self.data), "backups": sorted(self.names)}

    # ---- lifecycle

    def start(self, clock_offset: str | None | bool = False, setup: bool = True, reason: str | None = None) -> dict:
        """Starts the candidate; `clock_offset` False keeps the current offset, None clears it."""
        with self.lock:
            if self.closing.is_set():
                raise ServerError("the server lifecycle is shutting down")
            if self.running:
                raise ServerError("the server is already running")
            self.binary, self.commit = self.candidate.binary(), self.candidate.server_commit
            if clock_offset is not False:
                self.clock_offset = clock_offset or None
            private_directory(self.folder)
            self.backups.mkdir(mode=0o700, exist_ok=True)
            os.chmod(self.backups, 0o700)
            arguments = [str(self.binary), "--listen", f"127.0.0.1:{self.port}", "--data-dir", str(self.data),
                         "--backup-dir", str(self.backups), "--dev-allow-loopback-feeds",
                         "--refresh-interval", self.refresh_interval]
            if self.clock_offset:
                arguments += ["--dev-clock-offset", self.clock_offset]
            fresh = not self.data.exists() or not any(self.data.iterdir())
            log = open(self.log_path, "a")
            os.chmod(self.log_path, 0o600)
            log.write(f"\n--- start {time.strftime('%Y-%m-%dT%H:%M:%S')} {' '.join(arguments[1:])}\n")
            log.flush()
            try:
                with self.process_lock:
                    if self.closing.is_set():
                        raise ServerError("startup cancelled by shutdown")
                    self.process = owned_popen(arguments, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            finally:
                log.close()
            self.hung = False
            self.cookie = None
            try:
                self._await_health(fresh)
            except Exception as error:
                self.events.emit("server", "start_failed", pid=self.process.pid, commit=self.commit,
                                 code=self.process.poll(), error=str(error))
                raise
            first = (self.data / "setup-code").exists()
            if first and setup:
                self._set_up()
            event = self.events.emit("server", "started", pid=self.process.pid, commit=self.commit,
                                     clock_offset=self.clock_offset, reason=reason, set_up=first and setup or None)
            self.on_change(True, True)
            if first and setup and not self.keys.exists():
                self._export_keys()
            return event

    def _await_health(self, fresh: bool) -> None:
        """Waits for the health check (and, on a fresh data directory, the setup code file)."""
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.closing.is_set():
                raise ServerError("startup cancelled by shutdown")
            if self.process.poll() is not None:
                raise ServerError(f"the server exited ({self.process.returncode}); see {self.log_path}")
            try:
                with urllib.request.urlopen(self.base + "/healthz", timeout=2) as answer:
                    if answer.status == 200 and (not fresh or (self.data / "setup-code").exists()):
                        return
            except (urllib.error.URLError, OSError):
                pass
            self.closing.wait(0.05)
        raise ServerError("the server did not answer /healthz within 60 s")

    def _set_up(self) -> None:
        code = (self.data / "setup-code").read_text().strip()
        self.send("POST", "/v1/setup", {"username": ADMIN[0], "password": ADMIN[1], "setup_code": code}, admin=False)

    def _export_keys(self) -> None:
        """Once per data directory: stop, `keys export`, start (the bundle restores every later backup)."""
        if not self.passphrase.exists():
            self.passphrase.write_text(secrets.token_hex(24))
            os.chmod(self.passphrase, 0o600)
        self._terminate("keys export")
        self.keys.unlink(missing_ok=True)
        done = self._run_job([str(self.binary), "keys", "export", "--data-dir", str(self.data), "--out", str(self.keys),
                               "--passphrase-file", str(self.passphrase)], capture_output=True, text=True)
        if done.returncode != 0:
            raise ServerError("keys export failed: " + done.stderr.strip()[-1000:])
        self.start(reason="keys exported")

    def _terminate(self, reason: str | None) -> None:
        if not self.running:
            return
        if self.hung:
            self.process.send_signal(signal.SIGCONT)
            self.hung = False
        self.process.terminate()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise ServerError("the server did not stop within 30 s of SIGTERM; it was killed")
        self.events.emit("server", "stopped", pid=self.process.pid, code=self.process.returncode, reason=reason)
        self.on_change(False, True)

    def stop(self, reason: str | None = None) -> dict:
        with self.lock:
            if not self.running:
                raise ServerError("the server is not running")
            self._terminate(reason)
            return self.describe()

    def crash(self, reason: str | None = None, restart: bool = True) -> dict:
        """SIGKILL; the exit is confirmed before anything else. A restart runs on its own thread."""
        with self.lock:
            if not self.running:
                raise ServerError("the server is not running")
            pid = self.process.pid
            self.process.send_signal(signal.SIGKILL)
            self.process.wait()
            self.hung = False
            self.events.emit("server", "crashed", pid=pid, reason=reason)
            self.on_change(False, False)
            if restart:
                self.restarting = threading.Thread(target=self._restart_after_crash, daemon=True)
                self.restarting.start()
            return self.describe()

    def _restart_after_crash(self) -> None:
        try:
            self.start(reason="restart after crash")
        except Exception as error:  # reported through the log; the next command sees the server stopped
            self.events.emit("server", "start_failed", error=str(error))

    def await_restart(self, timeout: float = 120) -> None:
        thread = self.restarting
        if thread is not None:
            thread.join(timeout)
            if thread.is_alive():
                raise ServerError(f"restart thread did not finish within {timeout:g} s")

    def hang(self, reason: str | None = None) -> dict:
        with self.lock:
            if not self.running:
                raise ServerError("the server is not running")
            if not self.hung:
                self.process.send_signal(signal.SIGSTOP)
                self.hung = True
                self.events.emit("server", "hung", pid=self.process.pid, reason=reason)
            return self.describe()

    def resume(self) -> dict:
        with self.lock:
            if not self.running:
                raise ServerError("the server is not running")
            if self.hung:
                self.process.send_signal(signal.SIGCONT)
                self.hung = False
                self.events.emit("server", "resumed", pid=self.process.pid)
            return self.describe()

    def restart(self, clock_offset: str | None | bool = False) -> dict:
        """A clean stop, then start the candidate on the same data directory with the chosen clock offset."""
        with self.lock:
            if self.running:
                self._terminate("restart")
            return self.start(clock_offset=clock_offset, reason="restart")

    def wipe(self, setup: bool = True) -> dict:
        """An empty replacement server: the data directory is deleted and the server starts empty."""
        with self.lock:
            if self.running:
                self._terminate("wipe")
            shutil.rmtree(self.data, ignore_errors=True)
            self.keys.unlink(missing_ok=True)
            self.names.clear()
            self.events.emit("server", "wiped")
            return self.start(setup=setup, reason="wipe")

    def backup(self, name: str) -> dict:
        with self.lock:
            if not self.running or self.hung:
                raise ServerError("a backup needs the running server")
            if not self.keys.exists():  # set up outside the hub (a person's first setup on the web page)
                self._export_keys()
            answer = self.send("POST", "/v1/admin/backup", {})
            path = self.backups / answer["file"]
            self.names[name] = str(path)
            (self.backups / "names.json").write_text(json.dumps(self.names, indent=2))
            return self.events.emit("server", "backup", name=name, file=answer["file"], size=answer.get("size"))

    def restore(self, name: str) -> dict:
        with self.lock:
            if name not in self.names:
                raise ServerError(f"no backup named {name}")
            if not self.keys.exists():
                raise ServerError("no key bundle was exported for this data directory")
            if self.running:
                self._terminate(f"restore {name}")
            done = self._run_job([str(self.binary), "restore", "--data-dir", str(self.data), "--from", self.names[name],
                                   "--keys", str(self.keys), "--passphrase-file", str(self.passphrase)],
                                  capture_output=True, text=True)
            with open(self.log_path, "a") as log:
                log.write(f"\n--- restore {name}\n{done.stdout}{done.stderr}")
            if done.returncode != 0:
                raise ServerError(f"restore {name} failed: " + done.stderr.strip()[-1000:])
            self.events.emit("server", "restored", name=name)
            return self.start(reason=f"restored {name}")

    def witness(self, folder: Path) -> dict:
        """The server checks itself: stop, copy the data directory, run the witness on the copy, start."""
        with self.lock:
            was_running = self.running
            if was_running:
                self._terminate("witness")
            self.witnesses += 1
            target = folder / f"witness-{self.witnesses}"
            shutil.rmtree(target, ignore_errors=True)
            private_directory(target)
            shutil.copytree(self.data, target / "data", symlinks=True)
            source = self.candidate.source()
            started = time.monotonic()
            with open(target / "witness.log", "w") as log:
                done = self._run_job(["make", "-C", str(source), "acceptance-witness", f"DATA={target / 'data'}",
                                       f"GO={self.candidate.go()}"], stdout=log, stderr=subprocess.STDOUT,
                                      stdin=subprocess.DEVNULL)
            passed = done.returncode == 0
            event = self.events.emit("server", "witness", number=self.witnesses, passed=passed, code=done.returncode,
                                     seconds=round(time.monotonic() - started, 1), log=str(target / "witness.log"))
            if was_running:
                self.start(reason="after witness")
            return event

    def shutdown(self, remove_data: bool = False) -> dict:
        # Set this before waiting for the lifecycle lock: an in-flight startup observes cancellation,
        # and a queued crash restart cannot resurrect a child after the snapshot.
        self.closing.set()
        jobs = self.cancel_jobs()
        process = self.cancel_process()
        self.await_restart(timeout=10)
        if not self.lock.acquire(timeout=10):
            raise ServerError("in-flight server command did not cancel during shutdown")
        try:
            terminal = {"restart_thread_exited": True, "exited": True, "jobs": jobs, "process": process}
            if self.process is not None:
                if self.hung and self.process.poll() is None:
                    self.process.send_signal(signal.SIGCONT)
                    self.hung = False
                terminal.update(finish_process(self.process, timeout=10))
                self.events.emit("server", "stopped", **terminal, reason="hub shutdown")
            if remove_data:
                # Callers must retain logs first. Kept for explicit standalone lifecycle users.
                shutil.rmtree(self.data)
            return terminal
        finally:
            self.lock.release()

    def cancel_process(self) -> dict:
        """Cancel output/network waits without waiting for an in-flight startup's lifecycle lock."""
        self.closing.set()
        with self.process_lock:
            process = self.process
        if process is None:
            return {"exited": True, "started": False}
        if self.hung and process.poll() is None:
            process.send_signal(signal.SIGCONT)
        return finish_process(process, timeout=5)

    def cancel_jobs(self) -> list[dict]:
        """Cancel tracked key/restore/witness commands before joining startup/control threads."""
        self.closing.set()
        with self.job_lock:
            jobs = list(self.jobs)
        return [finish_process(job, timeout=10) for job in jobs]

    def _run_job(self, arguments: list[str], capture_output: bool = False, **options) -> subprocess.CompletedProcess:
        if capture_output:
            options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with self.job_lock:
            if self.closing.is_set():
                raise ServerError("server command cancelled by shutdown")
            process = owned_popen(arguments, **options)
            self.jobs.add(process)
        finalized = False
        try:
            output, error = process.communicate()
            finish_process(process, timeout=0, graceful=True)
            finalized = True
            return subprocess.CompletedProcess(arguments, process.returncode, output, error)
        finally:
            if finalized:
                with self.job_lock:
                    self.jobs.discard(process)

    # ---- requests as the administrator, or as a person through a web session

    def send(self, method: str, path: str, body: dict | None, session: dict | None = None, admin: bool = True,
             timeout: float = 60) -> dict:
        """A JSON request on the private port. Without `session`, as the administrator (signing in when needed)."""
        if session is None and admin and self.cookie is None:
            self._admin_sign_in()
        holder = session if session is not None else self.__dict__
        try:
            return self._send(method, path, body, holder, timeout)
        except urllib.error.HTTPError as error:
            if error.code == 401 and session is None and admin:  # a restore or wipe ended the session
                self._admin_sign_in()
                return self._send(method, path, body, holder, timeout)
            raise

    def _admin_sign_in(self) -> None:
        self.cookie = None
        self._send("POST", "/v1/auth/web", {"username": ADMIN[0], "password": ADMIN[1]}, self.__dict__, 30)

    def _send(self, method: str, path: str, body: dict | None, holder: dict, timeout: float) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        request.add_header("Origin", self.base)
        if holder.get("cookie"):
            request.add_header("Cookie", holder["cookie"])
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            cookie = answer.headers.get("Set-Cookie")
            if cookie:
                holder["cookie"] = cookie.split(";", 1)[0]
            return json.loads(answer.read() or b"{}")

    def create_account(self, password: str, username: str | None = None) -> dict:
        username = username or "journey-" + secrets.token_hex(6)
        answer = self.send("POST", "/v1/admin/accounts", {"username": username, "password": password, "is_admin": False})
        self.events.emit("server", "account", username=username, account_id=answer["account"]["account_id"])
        return {"username": username, "account_id": answer["account"]["account_id"]}

    def set_password(self, account_id: str, password: str) -> None:
        self.send("POST", f"/v1/admin/accounts/{account_id}/password", {"password": password})
        self.events.emit("server", "password_changed", account_id=account_id)

    def import_library(self, username: str, password: str, database: Path) -> dict:
        """The web client's library import (PROTOCOL §11.5): sign in, register a browser, upload, finish, wait for publication."""
        session: dict = {}
        self.send("POST", "/v1/auth/web", {"username": username, "password": password}, session)
        self.send("POST", "/v1/installations", {"install_id": str(uuid.uuid4()), "instance_nonce": str(uuid.uuid4()),
                                                "name": "Fixture browser", "app_version": "fixture",
                                                "capabilities": ["favorites", "history", "inbox", "queue", "statistics"]}, session)
        data = database.read_bytes()
        kind = "opml" if database.suffix.lower() == ".opml" else "android_db"
        reserved = self.send("POST", "/v1/import", {"kind": kind, "fingerprint": hashlib.sha256(data).hexdigest(),
                                                   "size": len(data), "file_name": database.name}, session)
        chunk = 3 << 20
        for number, start in enumerate(range(0, len(data), chunk)):
            self.send("PUT", f"/v1/import/{reserved['import_id']}/chunks/{number}",
                      {"data": base64.b64encode(data[start:start + chunk]).decode()}, session)
        self.send("POST", f"/v1/import/{reserved['import_id']}/finish", {}, session)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if self.closing.is_set():
                raise ServerError("import cancelled by shutdown")
            status = self.send("GET", f"/v1/import/{reserved['import_id']}", None, session)
            if status.get("status") in ("published", "failed"):
                self.events.emit("server", "imported", username=username, status=status.get("status"))
                return status
            self.closing.wait(0.2)
        raise ServerError("the import did not finish within 120 s")
