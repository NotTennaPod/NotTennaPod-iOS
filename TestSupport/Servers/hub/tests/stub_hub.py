"""A stand-in for the hub's control API in the fixture launcher's tests: `GET /status` answers the run folder, the
candidate and the server commit it was started with, as the hub does."""

import argparse
import json
import os
import signal
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--run-dir", required=True)
parser.add_argument("--server-commit", required=True)
parser.add_argument("--web-commit", required=True)
parser.add_argument("--active-commit", help="the commit the server runs (default: the candidate's)")
arguments, _ = parser.parse_known_args()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass

    def do_GET(self) -> None:
        body = json.dumps({"run": arguments.run_dir, "ready": True,
                           "candidate": {"server_commit": arguments.server_commit, "web_commit": arguments.web_commit},
                           "server": {"commit": arguments.active_commit or arguments.server_commit}}).encode()
        self.send_response(200 if self.path == "/status" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)


def stop(*_):
    # Stand-in lifecycle receipt for launcher identity tests; it represents only this synthetic server.
    threading.Thread(target=server.shutdown).start()


signal.signal(signal.SIGTERM, stop)
try:
    server.serve_forever(poll_interval=0.05)
finally:
    server.server_close()
    path = Path(os.environ["NTP_FIXTURE_TERMINAL_PATH"])
    retained = path.parent / (path.stem + "-synthetic-evidence")
    private = retained / "private"
    private.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(retained, 0o700)
    terminal = {"quiesced": True, "errors": []}
    receipt = private / "receipt.json"
    receipt.write_text(json.dumps({"terminal": terminal, "synthetic": True}) + "\n")
    os.chmod(receipt, 0o600)
    path.write_text(json.dumps({**terminal, "retained": str(retained), "synthetic": True}) + "\n")
    os.chmod(path, 0o600)
