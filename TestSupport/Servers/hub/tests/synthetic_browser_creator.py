"""Newly owned creator whose cleanup exits a browser leader but leaves its TERM-resistant renderer."""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from hub.processes import birth, group_members, owned_popen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("web", "signal"), required=True)
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--write-package", action="store_true")
    args = parser.parse_args()
    args.records.mkdir(parents=True, mode=0o700)
    def record(name, value):
        path = args.records / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
    browser_script = (
        "import signal,subprocess,sys\n"
        "sys.stdin.buffer.readline()\n"
        "renderer=subprocess.Popen([sys.executable,'-c',"
        "'import signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(1,flush=True); signal.pause()'],"
        "stdout=subprocess.PIPE)\n"
        "renderer.stdout.readline()\n"
        "print(renderer.pid,flush=True)\n"
        "signal.pause()\n")
    browser = owned_popen([sys.executable, "-c", browser_script], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    initial = json.loads(browser._ntp_ownership_path.read_text())
    browser.stdin.write(b"spawn renderer after initial receipt\n")
    browser.stdin.flush()
    renderer = int(browser.stdout.readline())
    recovery = {**initial, "members": {**initial["members"], str(renderer): birth(renderer)}}
    record("initial.json", initial)
    # Independent test-only emergency ownership; outside the registry under test so it cannot hide the bug.
    record("recovery.json", recovery)
    ready = {"creator": os.getpid(), "creator_group": os.getpgrp(), "browser": browser.pid, "renderer": renderer,
             "receipt": str(browser._ntp_ownership_path)}
    if args.write_package:
        Path("Package.resolved").write_bytes(b"changed by synthetic creator\n")

    def cancel(*_):
        before = json.loads(browser._ntp_ownership_path.read_text())
        captured = before.get("members", {}).get(str(renderer)) == recovery["members"][str(renderer)]
        browser.terminate()
        browser.wait(timeout=5)
        record("cancel.json", {
            "renderer_authenticated_before_cancel": captured, "browser_leader_exited": browser.returncode is not None,
            "renderer_survived_creator_cleanup": renderer in group_members(browser.pid)})
        print("synthetic creator final tail", file=sys.stderr, flush=True)
        browser.stdin.close()
        browser.stdout.close()

    if args.mode == "web":
        record("ready.json", ready)
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"id": request["id"], "ok": True, "result": {"protocol": 1, **ready}}), flush=True)
        cancel()
    else:
        def stopped(*_):
            cancel()
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, stopped)
        record("ready.json", ready)
        print("ready", flush=True)
        signal.pause()


if __name__ == "__main__":
    main()
