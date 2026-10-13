#!/usr/bin/env python3
"""Launch/finalize only explicitly recorded fixture process groups, retaining logs before unlinking receipts."""
from __future__ import annotations

import argparse
import json
import hashlib
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "TestSupport" / "Servers"))
from hub.evidence import private_directory, retain, write_private
from hub.candidate import pinned
from hub.processes import birth, group_members, finish_owned_group, finish_registered_groups, preflight_registered_groups


def finish(entry: dict, timeout: float = 60) -> dict:
    return finish_owned_group(entry, timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("launch", "stop", "wait-port", "owned"))
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--name")
    parser.add_argument("--port", type=int)
    parser.add_argument("--shutdown-timeout", type=float, default=60, help="supervisor grace budget; test-local overrides allowed")
    args, command = parser.parse_known_args()
    command = command[1:] if command[:1] == ["--"] else command
    if command and args.action != "launch":
        parser.error("unexpected command arguments")
    private_directory(args.state)
    if args.action == "owned":
        try:
            identity = json.loads((args.state / f"{args.name}.process.json").read_text())
            pid = int((args.state / f"{args.name}.pid").read_text())
            return 0 if identity["pid"] == pid and birth(pid) == identity["birth"] and birth(pid) else 1
        except (OSError, ValueError, KeyError):
            return 1
    if args.action == "wait-port":
        import socket
        deadline = time.monotonic() + 5
        condition = threading.Event()
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", args.port), timeout=0.2).close()
                return 0
            except OSError:
                condition.wait(0.05)
        return 1
    if args.action == "launch":
        if not args.name:
            parser.error("launch needs --name")
        if not command:
            parser.error("launch needs a command")
        log_path = args.state / f"{args.name}.log"
        ownership = args.state / f"{args.name}.groups"
        if ownership.exists():
            raise RuntimeError(f"prior detached ownership evidence remains: {ownership}; finalize it before relaunch")
        private_directory(ownership)
        terminal_path = args.state / f"{args.name}.terminal.json"
        terminal_path.unlink(missing_ok=True)
        if log_path.exists():
            # Previously stopped logs must already have a retained receipt; refuse silent overwrite.
            previous = args.state / "retained.json"
            if not previous.exists():
                raise RuntimeError(f"prior fixture evidence has no retained receipt: {log_path}")
            receipt = json.loads(previous.read_text())
            original = Path(receipt["evidence"]) / "private" / log_path.name
            if not receipt["quiesced"] or not original.exists() or hashlib.sha256(original.read_bytes()).digest() != hashlib.sha256(log_path.read_bytes()).digest():
                raise RuntimeError(f"prior fixture log changed after its retained snapshot: {log_path}")
        identity_path = args.state / f"{args.name}.process.json"
        write_private(identity_path, {"registered": False, "ownership": str(ownership.resolve()), "name": args.name})
        try:
            with open(log_path, "w") as log:
                os.chmod(log_path, 0o600)
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                           start_new_session=True,
                                           env=dict(os.environ, NTP_FIXTURE_OWNERSHIP_DIR=str(ownership.resolve()),
                                                    NTP_FIXTURE_TERMINAL_PATH=str(terminal_path.resolve())))
        except BaseException:
            write_private(identity_path, {"registered": True, "spawn_failed": True, "exited": True,
                                          "ownership": str(ownership.resolve()), "name": args.name})
            raise
        identity = {"registered": True, "pid": process.pid, "birth": birth(process.pid), "name": args.name,
                    "port": args.port, "members": {str(process.pid): birth(process.pid)},
                    "ownership": str(ownership.resolve()),
                    "terminal": str(terminal_path.resolve()) if args.name == "ntp-server" else None}
        write_private(identity_path, identity)
        pid_path = args.state / f"{args.name}.pid"
        pid_path.write_text(str(process.pid) + "\n")
        os.chmod(pid_path, 0o600)
        return 0
    errors, terminals = [], []
    names = sorted({path.stem for path in args.state.glob("*.pid")} |
                   {path.name.removesuffix(".process.json") for path in args.state.glob("*.process.json")} |
                   {path.name.removesuffix(".groups") for path in args.state.glob("*.groups")})
    for name in names:
        path = args.state / f"{name}.pid"
        receipt = args.state / f"{name}.process.json"
        try:
            if not receipt.exists():
                raise RuntimeError(f"no supervisor ownership receipt for {name}; no process was guessed or signalled")
            entry = json.loads(receipt.read_text())
            if path.exists() and entry.get("pid") != int(path.read_text()):
                raise RuntimeError(f"PID receipt disagrees with {receipt}")
            # The supervisor cancels and retains first. If it needs escalation, detached groups still
            # have their own durable identities; supervisor exit alone never proves their exit.
            supervisor = None
            finalization_errors = []
            try:
                preflight_registered_groups(Path(entry["ownership"]))
                supervisor = finish(entry, args.shutdown_timeout)
                terminals.append(supervisor)
            except Exception as error:
                finalization_errors.append(f"supervisor: {error}")
            try:
                # Independently owned groups are finalized even when the supervisor is unverifiable.
                terminals.extend(finish_registered_groups(Path(entry["ownership"])))
            except Exception as error:
                finalization_errors.append(str(error))
            if finalization_errors:
                raise RuntimeError("; ".join(finalization_errors))
            if entry.get("terminal"):
                hub = json.loads(Path(entry["terminal"]).read_text())
                if not hub.get("quiesced") or hub.get("errors") or hub.get("retention_failed") or not hub.get("retained"):
                    raise RuntimeError("Hub terminal shutdown/retention receipt reports incomplete finalization")
                retained_receipt = Path(hub.get("retained", "")) / "private" / "receipt.json"
                retained_hub = json.loads(retained_receipt.read_text())
                if not retained_hub["terminal"].get("quiesced"):
                    raise RuntimeError("Hub terminal shutdown/retention receipt reports incomplete finalization")
                if supervisor["forced"]:
                    raise RuntimeError("Hub supervisor deadline required SIGKILL; original evidence and ownership preserved")
        except Exception as error:
            errors.append(str(error))
    terminal = {"quiesced": not errors, "children": terminals, "errors": errors}
    candidate = {"server_commit": pinned("server-version.txt"), "web_commit": pinned("web-version.txt")}
    try:
        retained = retain(args.state, ROOT / ".work" / "fixture-evidence", "fixture-launcher", candidate, terminal,
                          "; ".join(errors) or None, logs=sorted(args.state.glob("*.log")))
        write_private(args.state / "retained.json", {"evidence": str(retained), **terminal})
    except Exception as error:
        errors.append(f"launcher evidence retention: {error}")
        terminal["quiesced"] = False
        write_private(args.state / "retained.json", {**terminal, "retention_failed": True})
    if errors:
        print("fixture-process: " + "; ".join(errors), file=sys.stderr)
        return 1
    for name in names:
        path = args.state / f"{name}.pid"
        entry_path = args.state / f"{name}.process.json"
        if entry_path.exists():
            entry = json.loads(entry_path.read_text())
            shutil.rmtree(entry["ownership"], ignore_errors=False)
        path.unlink(missing_ok=True)
        entry_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
