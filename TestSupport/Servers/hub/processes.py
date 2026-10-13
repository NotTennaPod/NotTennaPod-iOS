"""Confirm exits of test-owned subprocess groups, including browser/build descendants."""
from __future__ import annotations

import os
import json
import fcntl
import signal
import subprocess
import threading
import time
import uuid
from pathlib import Path


def birth(pid: int, timeout: float = 5) -> str:
    # ps exits 1 when the PID has already exited/reaped; that is an absent identity, not a probe crash.
    answer = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, check=False, timeout=timeout)
    return answer.stdout.strip()


def _receipt(path: Path, entry: dict, timeout: float = 5) -> None:
    # External preflight and a creator's terminal update can overlap. Preserve authenticated members
    # even when the creator still holds an older in-memory receipt, and serialize the read/merge/write.
    with path.with_suffix(".lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        deadline, condition = time.monotonic() + timeout, threading.Event()
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                condition.wait(min(0.02, _remaining(deadline)))
        previous = json.loads(path.read_text()) if path.exists() else {}
        if (previous.get("pid"), previous.get("birth")) == (entry.get("pid"), entry.get("birth")):
            if previous.get("exited"):
                entry = {**entry, **previous}  # A concurrent terminal receipt cannot become live again.
            entry = {**entry, "members": {**previous.get("members", {}), **entry.get("members", {})}}
        temporary = path.with_suffix("." + uuid.uuid4().hex + ".tmp")
        with temporary.open("w") as output:
            os.chmod(temporary, 0o600)
            json.dump(entry, output, sort_keys=True)
            output.write("\n")
        temporary.replace(path)


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("detached ownership preflight exceeded its budget; evidence preserved")
    return remaining


def owned_popen(*arguments, **options) -> subprocess.Popen:
    """Register every detached Hub child for its supervisor's external finalizer.

    A launch intent is durable before spawning. If the supervisor dies between spawn and registration,
    that unresolved intent prevents a false successful finalization; unknown processes are never guessed.
    """
    options["start_new_session"] = True
    registry = options.get("env", os.environ).get("NTP_FIXTURE_OWNERSHIP_DIR")
    path = None
    if registry:
        folder = Path(registry)
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(folder, 0o700)
        path = folder / (uuid.uuid4().hex + ".json")
        _receipt(path, {"registered": False, "supervisor": os.getpid()})
    try:
        process = subprocess.Popen(*arguments, **options)
    except BaseException:
        if path:
            _receipt(path, {"registered": True, "spawn_failed": True, "exited": True})
        raise
    process._ntp_finish_lock = threading.RLock()
    process._ntp_ownership_path = path
    process._ntp_ownership = {"registered": True, "pid": process.pid, "birth": birth(process.pid),
                              "members": {}, "exited": False, "supervisor": os.getpid()}
    if path:
        _update_ownership(process)
    return process


def _update_ownership(process: subprocess.Popen, terminal: dict | None = None) -> None:
    path = getattr(process, "_ntp_ownership_path", None)
    if path:
        entry = process._ntp_ownership
        # While the original leader exists, its group membership authenticates these descendants.
        if birth(process.pid) == entry["birth"] and entry["birth"]:
            entry["members"].update({str(pid): birth(pid) for pid in group_members(process.pid)})
        if terminal:
            entry.update(terminal)
        _receipt(path, entry)


def verify_owned_group(entry: dict, timeout: float = 5) -> list[int]:
    if not entry.get("registered"):
        raise RuntimeError("detached child launch registration is incomplete; ownership evidence preserved")
    if entry.get("spawn_failed"):
        return []
    if entry.get("exited"):
        # Only written after confirmed whole-group exit; a later PID reuse belongs to somebody else.
        return []
    pid = int(entry["pid"])
    deadline = time.monotonic() + timeout
    current = birth(pid, timeout=_remaining(deadline))
    members = group_members(pid, timeout=_remaining(deadline))
    if current and current != entry["birth"]:
        raise RuntimeError(f"test-owned PID {pid} has been reused; it was not signalled")
    if members and not current:
        known = entry.get("members", {})
        if not any(known.get(str(member)) and known[str(member)] == birth(member, timeout=_remaining(deadline)) for member in members):
            raise RuntimeError(f"test-owned group {pid} has no surviving authenticated member; it was not signalled")
    return members


def preflight_registered_groups(registry: Path, timeout: float = 5) -> list[dict]:
    """Authenticate and retain current members BEFORE creator EOF/signals, without signalling anything.

    One bounded snapshot plus a rescan captures registrations arriving during the first pass. Unresolved
    launches/reused identities fail closed. Later finalization still rescans after creator exit.
    """
    deadline = time.monotonic() + timeout
    captured, processed, errors = [], set(), []
    for _ in range(2):
        for path in sorted(set(registry.rglob("*.json")) - processed):
            try:
                entry = json.loads(path.read_text())
                members = verify_owned_group(entry, timeout=_remaining(deadline))
                if members:
                    identities = {str(member): birth(member, timeout=_remaining(deadline)) for member in members}
                    entry.setdefault("members", {}).update({pid: identity for pid, identity in identities.items() if identity})
                    _receipt(path, entry, timeout=_remaining(deadline))
                captured.append(entry)
            except Exception as error:
                errors.append(f"{path.name}: {error}")
            processed.add(path)
    if errors:
        raise RuntimeError("detached ownership preflight: " + "; ".join(errors))
    return captured


def finish_owned_group(entry: dict, timeout: float = 5) -> dict:
    """Externally finalize a durably registered group, with no assumption about its supervisor."""
    members = verify_owned_group(entry)
    if entry.get("spawn_failed"):
        return {"exited": True, "spawn_failed": True}
    pid = int(entry["pid"])
    if members:
        operation = "SIGCONT"
        try:
            _signal_group(pid, signal.SIGCONT)
            operation = "SIGTERM"
            _signal_group(pid, signal.SIGTERM)
        except OSError as error:
            raise RuntimeError(f"owned group {pid}: {operation} failed (errno {error.errno}); authenticated members {members}") from error
    condition = threading.Event()
    deadline = time.monotonic() + timeout
    while members and time.monotonic() < deadline:
        condition.wait(0.02)
        members = group_members(pid)
    forced = bool(members)
    if members:
        members = verify_owned_group(entry)  # Re-authenticate; a group that has exited since needs no SIGKILL.
    if members:
        try:
            _signal_group(pid, signal.SIGKILL)
        except OSError as error:
            raise RuntimeError(f"owned group {pid}: SIGKILL failed (errno {error.errno}); authenticated members {members}") from error
        deadline = time.monotonic() + 10
        while members and time.monotonic() < deadline:
            condition.wait(0.02)
            members = group_members(pid)
    if members:
        raise RuntimeError(f"test-owned group {pid} did not exit: {members}")
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return {"pid": pid, "exited": True, "forced": forced}


def finish_registered_groups(registry: Path, timeout: float = 5) -> list[dict]:
    terminals, errors, processed = [], [], set()
    # Finish creator groups before their detached children, then rescan: an in-flight actor spawn
    # can complete its durable receipt while the actor itself is being cancelled.
    while pending := sorted(set(registry.rglob("*.json")) - processed):
        try:
            preflight_registered_groups(registry)
        except Exception as error:
            errors.append(str(error))  # Still finalize the independently authenticated groups below.
        entries = {}
        for path in pending:
            try:
                entry = json.loads(path.read_text())
                entries[path] = entry
            except Exception as error:
                errors.append(f"{path.name}: {error}")
                processed.add(path)
        by_pid = {entry.get("pid"): entry for entry in entries.values() if entry.get("pid")}

        def depth(path):
            entry, seen = entries[path], set()
            parent = entry.get("supervisor")
            while parent in by_pid and parent not in seen:
                seen.add(parent)
                parent = by_pid[parent].get("supervisor")
            return len(seen)

        for path in sorted(entries, key=depth):
            try:
                entry = json.loads(path.read_text())  # A creator may have finalized its receipt during cancellation.
                terminal = finish_owned_group(entry, timeout)
                terminals.append(terminal)
                _receipt(path, {**entry, **terminal})
            except Exception as error:
                errors.append(f"{path.name}: {error}")
            finally:
                processed.add(path)
    if errors:
        raise RuntimeError("detached group finalization: " + "; ".join(errors))
    return terminals


def _signal_group(group: int, sig: int) -> None:
    """killpg that treats an already-exited group as gone.

    XNU answers EPERM (not ESRCH) when every remaining member of a group is an unreaped zombie, e.g. a
    leader that exited between the membership scan and the signal. Zombies have exited, so an EPERM with
    no live member left is an exited group; with live members it stays a real refusal and is raised.
    """
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        if group_members(group):
            raise


def group_members(group: int, timeout: float = 5) -> list[int]:
    # Zombies have exited and cannot write evidence. Never examine or signal unrelated process groups.
    answer = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="], capture_output=True, text=True, check=True, timeout=timeout)
    return [int(parts[0]) for line in answer.stdout.splitlines()
            if len(parts := line.split()) == 3 and int(parts[1]) == group and not parts[2].startswith("Z")]


def finish_process(process: subprocess.Popen, timeout: float = 20, graceful: bool = False) -> dict:
    """Processes must have been spawned with start_new_session=True. Always reap after forced kill."""
    lock = getattr(process, "_ntp_finish_lock", None)
    if lock is None:
        lock = process._ntp_finish_lock = threading.RLock()
    with lock:
        _update_ownership(process)
        terminal = _finish_process(process, timeout, graceful)
        _update_ownership(process, terminal)
        return terminal


def _finish_process(process: subprocess.Popen, timeout: float, graceful: bool) -> dict:
    group = process.pid
    process.poll()
    members = group_members(group)
    if process.returncode is not None and group in members:
        # A reaped leader cannot be alive. Its PID/session has been reused; never signal the replacement.
        raise RuntimeError(f"test-owned process group {group} has a reused leader; it was not signalled")
    if not graceful:
        _signal_group(group, signal.SIGTERM)
    forced = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        forced = True
        _signal_group(group, signal.SIGKILL)
        process.wait(timeout=10)
    members = group_members(group)
    if members:
        forced = True
        _signal_group(group, signal.SIGKILL)
        deadline = time.monotonic() + 10
        condition = threading.Event()
        while members and time.monotonic() < deadline:
            condition.wait(0.02)
            members = group_members(group)
    process.wait(timeout=10)
    if members:
        raise RuntimeError(f"test-owned process group {group} did not exit: {members}")
    return {"pid": process.pid, "code": process.returncode, "forced": forced, "exited": True}
