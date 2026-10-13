#!/usr/bin/env python3
"""The acceptance hub (PROTOCOL §16): the real NotTennaPod server for the UI journeys, behind a fault
proxy, with the publisher, the app and web bridges, the wire client R and the two-installation transplant.

The server is the release candidate: the commit pinned in TestSupport/Server/server-version.txt with the web client
pinned in web-version.txt, built by `Tools/ntp-server.sh --with-web` from archived copies of the sibling checkouts
(the checkouts are never changed). Apps and browsers use the proxy on 127.0.0.1:18830, which passes everything
through to the server on a private port until a journey sets a fault; the control API is on 127.0.0.1:18831 and
answers at once (`GET /ready` waits until everything runs). The API is described in hub/control.py.

The NotTennaPod scheme's test pre-action starts it (Tools/test-fixtures.sh). The run's folder (`--run-dir`, by default
.work/test-fixtures/hub) holds the event log, the server's data, backups and log, the web actor's log and the
witnesses' copies; without `--keep`, SIGTERM stops everything and removes the server's data. Passwords and tokens are
never printed.
"""

from __future__ import annotations

import argparse
import signal
import sys
import threading
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hub.candidate import ROOT  # noqa: E402
from hub.control import Hub  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18831, help="the control API")
    parser.add_argument("--server-port", type=int, default=18830, help="the server's public port: the fault proxy")
    parser.add_argument("--private-port", type=int, default=0, help="the server itself (default: a free port)")
    parser.add_argument("--publisher-port", type=int, default=18834)
    parser.add_argument("--run-dir", type=Path, default=ROOT / ".work" / "test-fixtures" / "hub")
    parser.add_argument("--keep", action="store_true", help="keep the run's folder, the server's data included")
    arguments = parser.parse_args()
    # Every ordinary invocation has its own folder. Never erase a previous run's unfinished logs,
    # children or recovery inputs at startup. Acceptance --keep retains its explicitly named folder.
    run = arguments.run_dir.resolve()
    if not arguments.keep:
        run = run / ("run-" + uuid.uuid4().hex)
    elif (run / "events.jsonl").exists():
        parser.error("--keep run already has evidence; use a new run directory")
    hub = Hub(run, control_port=arguments.port, proxy_port=arguments.server_port, server_port=arguments.private_port,
              publisher_port=arguments.publisher_port, keep=arguments.keep)

    stopping = threading.Event()

    def stop(*_) -> None:
        # shutdown() cannot run on serve_forever's own signal-handler thread.
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=hub.stop, daemon=False).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    hub.launch()
    print(f"NotTennaPod hub control at http://127.0.0.1:{hub.control.server_address[1]} (run {run})", flush=True)
    try:
        hub.control.serve_forever()
    finally:
        hub.stop()


if __name__ == "__main__":
    main()
