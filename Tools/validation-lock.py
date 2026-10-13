#!/usr/bin/env python3
"""One checkout-local lock for host validation, fixture mutations and contract resync.

fcntl waits for ownership; inherited, verified lock descriptors make nested fixture pre-actions safe.
Host and sync commands require inactive fixture processes. The ordinary acceptance rows remain serial.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import importlib.util
import os
import subprocess
import sys
import signal
import stat
import secrets
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def managed_processes(folder: Path):
    """Only load Hub helpers when managed receipts exist; copied Tools-only roots stay self-sufficient."""
    helper = ROOT / "TestSupport" / "Servers" / "hub" / "processes.py"
    if not helper.exists():
        raise RuntimeError("managed detached ownership exists but its finalizer is unavailable")
    spec = importlib.util.spec_from_file_location("validation_owned_processes", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def preflight_managed(folder: Path | None) -> None:
    if folder and list((folder / "groups").rglob("*.json")):
        managed_processes(folder).preflight_registered_groups(folder / "groups")


def finish_command(process: subprocess.Popen, timeout: float = 30, managed: Path | None = None) -> None:
    """Finalize the directly owned command group without depending on the Hub package.

    Contract-vector checks deliberately copy only Tools and their input fixtures into an isolated root.
    """
    def cancel(number):
        preflight_managed(managed)
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            pass

    def members():
        listing = subprocess.run(["ps", "-axo", "pid=,pgid=,stat="], capture_output=True, text=True, check=True)
        return [int(parts[0]) for line in listing.stdout.splitlines()
                if len(parts := line.split()) == 3 and int(parts[1]) == process.pid and not parts[2].startswith("Z")]

    process.poll()
    remaining = members()
    if process.returncode is not None and process.pid in remaining:
        raise RuntimeError("validation command group leader was reused; replacement was not signalled")
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        cancel(signal.SIGKILL)
        process.wait(timeout=10)
    remaining = members()
    if remaining:
        if process.returncode is not None and process.pid in remaining:
            raise RuntimeError("validation command group leader was reused; replacement was not signalled")
        # A Foundation-launched Hub shares this group. Give its signal handler time to cancel
        # detached children and retain terminal evidence before supervisor escalation.
        cancel(signal.SIGTERM)
        deadline = time.monotonic() + timeout
        condition = threading.Event()
        while remaining and time.monotonic() < deadline:
            condition.wait(0.02)
            remaining = members()
        if remaining:
            if process.pid in remaining:
                raise RuntimeError("validation command group leader was reused; replacement was not signalled")
            cancel(signal.SIGKILL)
        deadline = time.monotonic() + 10
        condition = threading.Event()
        while remaining and time.monotonic() < deadline:
            condition.wait(0.02)
            remaining = members()
    if remaining:
        raise RuntimeError(f"validation command group did not exit: {remaining}")
    process.wait(timeout=10)


def finish_managed(folder: Path, primary_code: int | None) -> dict:
    """Detached Hub children and successful terminal retention are independent of Swift group exit."""
    errors, groups = [], []
    if list((folder / "groups").rglob("*.json")):
        try:
            groups = managed_processes(folder).finish_registered_groups(folder / "groups")
        except Exception as error:
            errors.append(str(error))
    groups_exited = not errors
    for path in sorted((folder / "hubs").glob("*.json")):
        try:
            hub = json.loads(path.read_text())
            if not hub.get("quiesced") or hub.get("errors") or hub.get("retention_failed") or not hub.get("retained"):
                raise RuntimeError("Hub terminal shutdown/retention is incomplete")
            receipt = json.loads((Path(hub["retained"]) / "private" / "receipt.json").read_text())
            if not receipt["terminal"].get("quiesced"):
                raise RuntimeError("retained Hub evidence reports incomplete finalization")
        except Exception as error:
            errors.append(f"{path.name}: {error}")
    receipt_path = folder / "terminal.json"
    result = {"quiesced": not errors, "groups_exited": groups_exited, "primary_code": primary_code,
              "groups": groups, "errors": errors}
    receipt_path.write_text(json.dumps(result, sort_keys=True) + "\n")
    os.chmod(receipt_path, 0o600)
    if not errors:
        (folder / "unfinished.json").unlink(missing_ok=True)
    return result


def verified_descriptor(lock_path: Path) -> int | None:
    inherited = os.environ.get("NTP_VALIDATION_LOCK_FD")
    if inherited:
        try:
            descriptor = int(inherited)
            held, expected = os.fstat(descriptor), lock_path.stat()
            if (held.st_dev, held.st_ino) == (expected.st_dev, expected.st_ino):
                return descriptor
        except (OSError, ValueError):
            pass
    return None


def verified_readonly_owner(lock_path: Path) -> bool:
    """Foundation may close extra descriptors. Only read-only checks may use an authenticated ancestor lease."""
    try:
        owner = json.loads(lock_path.with_name("lock-owner.json").read_text())
        if owner["token"] != os.environ.get("NTP_VALIDATION_LOCK_TOKEN") or str(owner["pid"]) != os.environ.get("NTP_VALIDATION_LOCK_OWNER"):
            return False
        ancestor = os.getpid()
        for _ in range(64):
            if ancestor == owner["pid"]:
                break
            parent = subprocess.run(["ps", "-o", "ppid=", "-p", str(ancestor)], capture_output=True, text=True)
            ancestor = int(parent.stdout.strip())
            if ancestor <= 1:
                return False
        else:
            return False
        with lock_path.open("r+") as descriptor:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    except (OSError, ValueError, KeyError):
        pass
    return False


def fixture_leases(index: Path, inherited_managed: str | None = None) -> tuple[list[str], list[str]]:
    states = {str(ROOT / ".work" / "test-fixtures")}
    if index.exists():
        states.update(json.loads(index.read_text()))
    active = []
    unleased = []
    for pending in sorted((index.parent / "managed").glob("*/unfinished.json")):
        if inherited_managed and pending.parent.resolve() == Path(inherited_managed).resolve():
            continue  # Authenticated nested work still belongs to the active outer invocation.
        active.append(f"{pending.parent} (managed shutdown ownership unresolved; explicit finalization required)")
    for state in sorted(states):
        registry = Path(state) / "users.d"
        registrations = len(list(registry.iterdir())) if registry.is_dir() else 0
        legacy_users = Path(state) / "users"
        if legacy_users.exists():
            try:
                registrations += int(legacy_users.read_text())
            except ValueError:
                active.append(f"{state} (test lease ownership unresolved)")
        if registrations:
            active.append(f"{state} ({registrations} unreleased test lease(s))")
        for pid_file in Path(state).glob("*.pid"):
            try:
                os.kill(int(pid_file.read_text()), 0)
                (active if registrations else unleased).append(f"{state}/{pid_file.name}")
            except ProcessLookupError:
                pass
            except (ValueError, PermissionError):
                (active if registrations else unleased).append(f"{state}/{pid_file.name} (process ownership unresolved)")
    return active, unleased


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("host", "sync", "fixture"))
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--verify-readonly", action="store_true")
    parser.add_argument("--fixture-state", type=Path)
    parser.add_argument("--restore-package-resolved", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.verify:
        return 0 if verified_descriptor(ROOT / ".work" / "validation" / "host-fixture.lock") is not None else 1
    if args.verify_readonly:
        return 0 if verified_readonly_owner(ROOT / ".work" / "validation" / "host-fixture.lock") else 1
    if not command or args.kind is None:
        parser.error("a command is required")
    folder = ROOT / ".work" / "validation"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    lock_path = folder / "host-fixture.lock"
    descriptor = verified_descriptor(lock_path)
    if descriptor is None and os.environ.get("NTP_VALIDATION_LOCK_FD"):
        print("validation: nested command did not inherit its lock descriptor; forward it with pass_fds", file=sys.stderr)
        return 1
    owned = descriptor is None
    if owned:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
    owner_path = folder / "lock-owner.json"
    token = secrets.token_hex(24) if owned else os.environ.get("NTP_VALIDATION_LOCK_TOKEN", "")
    if owned:
        owner_path.write_text(json.dumps({"pid": os.getpid(), "token": token}) + "\n")
        os.chmod(owner_path, 0o600)
    try:
        index = folder / "fixture-states.json"
        if args.kind in ("host", "sync"):
            active, unleased = fixture_leases(index, os.environ.get("NTP_MANAGED_INVOCATION_DIR") if not owned else None)
            receipt = folder / "lease-observation.json"
            receipt.write_text(json.dumps({"active_test_leases": active, "unleased_idle_or_unclassified_pids": unleased}) + "\n")
            os.chmod(receipt, 0o600)
            if active:
                print("validation: stop the test-owned fixtures before a quiet host/resync command: " + ", ".join(active),
                      file=sys.stderr)
                return 1
        if args.fixture_state:
            states = set(json.loads(index.read_text())) if index.exists() else set()
            states.add(str(args.fixture_state.resolve()))
            index.write_text(json.dumps(sorted(states)) + "\n")
            os.chmod(index, 0o600)
        environment = dict(os.environ, NTP_VALIDATION_LOCK_FD=str(descriptor), NTP_VALIDATION_LOCK_TOKEN=token,
                           NTP_VALIDATION_LOCK_OWNER=str(os.getpid()) if owned else os.environ.get("NTP_VALIDATION_LOCK_OWNER", ""))
        managed = None
        if args.kind == "host":
            managed = folder / "managed" / secrets.token_hex(12)
            for private in (managed.parent, managed, managed / "groups", managed / "hubs"):
                private.mkdir(mode=0o700, parents=True, exist_ok=True)
                os.chmod(private, 0o700)
            unfinished = managed / "unfinished.json"
            unfinished.write_text(json.dumps({"guard_pid": os.getpid(), "kind": args.kind}) + "\n")
            os.chmod(unfinished, 0o600)
            environment.update(NTP_MANAGED_INVOCATION_DIR=str(managed.resolve()),
                               NTP_FIXTURE_OWNERSHIP_DIR=str((managed / "groups").resolve()),
                               NTP_HUB_TERMINAL_REGISTRY=str((managed / "hubs").resolve()))
            environment.pop("NTP_FIXTURE_TERMINAL_PATH", None)
        resolved = ROOT / "Package.resolved"
        before = resolved.read_bytes() if args.restore_package_resolved and resolved.exists() else None
        mode = stat.S_IMODE(resolved.stat().st_mode) if before is not None else 0o644
        process = None

        def interrupt(number, _frame):
            raise InterruptedError(number)

        previous = {number: signal.signal(number, interrupt) for number in (signal.SIGINT, signal.SIGTERM)}
        try:
            process = subprocess.Popen(command, env=environment, pass_fds=(descriptor,), start_new_session=True)
            try:
                return process.wait()
            except InterruptedError as error:
                for number in previous:
                    signal.signal(number, signal.SIG_IGN)
                preflight_managed(managed)
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    preflight_managed(managed)
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                return 128 + int(error.args[0])
        finally:
            retention_error = None
            try:
                if process is not None:
                    command_error = None
                    try:
                        finish_command(process, managed=managed)
                    except Exception as error:
                        command_error = error
                    managed_error = None
                    if managed:
                        try:
                            terminal = finish_managed(managed, process.returncode)
                            if terminal["errors"]:
                                failure = RuntimeError("managed validation finalization: " + "; ".join(terminal["errors"]))
                                if terminal["groups_exited"]:
                                    retention_error = failure  # All possible writers exited; restore before reporting retention failure.
                                else:
                                    managed_error = failure
                        except Exception as error:
                            managed_error = error
                    if command_error or managed_error:
                        if managed and not (managed / "unfinished.json").exists():
                            pending = managed / "unfinished.json"
                            pending.write_text(json.dumps({"command_finalization_failed": True}) + "\n")
                            os.chmod(pending, 0o600)
                        raise RuntimeError("; ".join(str(error) for error in (command_error, managed_error) if error))
                elif managed:
                    finish_managed(managed, None)  # Popen failed before any command/Hub could become a writer.
            except BaseException:
                # A writer that has not been confirmed exited could overwrite an early restoration.
                # Preserve the exact original privately and fail; restoration waits for finalization.
                if args.restore_package_resolved:
                    pending = folder / ("restore-pending-" + secrets.token_hex(12))
                    pending.mkdir(mode=0o700)
                    if before is not None:
                        saved = pending / "Package.resolved"
                        saved.write_bytes(before)
                        os.chmod(saved, 0o600)
                    receipt = pending / "receipt.json"
                    receipt.write_text(json.dumps({"original_existed": before is not None, "original_mode": mode,
                                                   "restoration_pending": True, "child_group": process.pid if process else None,
                                                   "primary_code": process.returncode if process else None,
                                                   "managed_directory": str(managed) if managed else None}) + "\n")
                    os.chmod(receipt, 0o600)
                raise
            else:
                if args.restore_package_resolved:
                    if before is None:
                        resolved.unlink(missing_ok=True)
                    else:
                        resolved.write_bytes(before)
                        os.chmod(resolved, mode)
                if retention_error:
                    raise retention_error
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
    finally:
        if owned:
            owner_path.unlink(missing_ok=True)
            os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
