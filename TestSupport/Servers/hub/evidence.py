"""Retain finalized, test-owned logs before deleting disposable data.

Raw logs are private (0700 directories, 0600 files). Shareable events use an explicit field allowlist;
free-form errors, request URLs and child output stay private. Data, backups, setup codes and key inputs
are never copied here. A witness's stopped data copy is authorized by the witness command itself.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import time
import uuid
from pathlib import Path

SAFE_EVENT_FIELDS = {"seq", "t", "wall_ms", "source", "kind", "pid", "code", "commit", "server_commit",
                     "web_commit", "clock_offset", "clock_offset_ms", "passed", "seconds", "number", "status",
                     "method", "protocol", "set_up", "graceful"}


def private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(path, 0o600)


def retain(run: Path, destination: Path, identity: str, candidate: dict, terminal: dict,
           primary_error: str | None = None, logs: list[Path] | None = None) -> Path:
    """Log-only snapshot. Missing/truncated logs and failed quiescence remain explicit in the receipt.

    Retention is bounded by an allowlist of evidence files rather than recursive copying of a run.
    Evidence is immutable per invocation; existing receipts are never overwritten or silently pruned.
    """
    label = re.sub(r"[^A-Za-z0-9_.-]+", "-", identity)[:100] or "hub"
    commits = "-".join(str(candidate.get(key) or "unknown")[:12] for key in ("server_commit", "web_commit"))
    parent = destination / commits
    private_directory(destination)
    private_directory(parent)
    target = parent / f"{label}-{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:12]}"
    private_directory(target)
    private = target / "private"
    private_directory(private)
    shareable = target / "shareable"
    shareable.mkdir()
    expected = logs if logs is not None else [run / "events.jsonl", run / "server" / "server.log"]
    optional = [run / "web" / "actor.log", *sorted((run / "candidate").glob("*.log")),
                *sorted((run / "witness").glob("*/witness.log"))]
    files, issues = [], []
    if not terminal.get("quiesced", False):
        issues.append({"file": "*", "issue": "writers not confirmed stopped; snapshot may be incomplete"})
    for path in [*expected, *optional]:
        relative = path.relative_to(run)
        if not path.is_file():
            issues.append({"file": str(relative), "issue": "missing"})
            continue
        output = private / relative
        private_directory(output.parent)
        shutil.copyfile(path, output)
        os.chmod(output, 0o600)
        data = output.read_bytes()
        files.append({"file": str(relative), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        if data and not data.endswith(b"\n"):
            issues.append({"file": str(relative), "issue": "unterminated final line; may be truncated"})
    events = []
    event_path = private / "events.jsonl"
    if event_path.exists():
        for number, line in enumerate(event_path.read_text(errors="replace").splitlines(), 1):
            try:
                event = json.loads(line)
                events.append({key: value for key, value in event.items() if key in SAFE_EVENT_FIELDS})
            except (ValueError, AttributeError):
                issues.append({"file": "events.jsonl", "line": number, "issue": "invalid event; may be truncated"})
    (shareable / "events.jsonl").write_text("".join(json.dumps(event, sort_keys=True) + "\n" for event in events))
    receipt = {"identity": identity, "candidate": candidate, "terminal": terminal,
               "primary_error": primary_error, "files": files, "issues": issues,
               "data_copied": False, "shareable_policy": "allowlisted event fields; raw child logs remain private"}
    write_private(private / "receipt.json", receipt)
    public_receipt = {"identity": label, "candidate": {key: candidate.get(key) for key in ("server_commit", "web_commit")},
                      "quiesced": terminal.get("quiesced", False), "primary_error_recorded": primary_error is not None,
                      "issues": issues, "files": files, "data_copied": False}
    (shareable / "receipt.json").write_text(json.dumps(public_receipt, indent=2, sort_keys=True) + "\n")
    return target
