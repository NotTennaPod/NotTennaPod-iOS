"""Launcher negative-path stand-in using the real Hub and a synthetic health-only Server."""
from __future__ import annotations

import argparse
import signal
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from hub.control import Hub

parser = argparse.ArgumentParser()
parser.add_argument("--run-dir", type=Path, required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--failure", choices=("blocked-startup", "retention"), required=True)
args = parser.parse_args()
args.run_dir.mkdir(parents=True, mode=0o700)
binary = args.run_dir / "synthetic-server"
binary.write_text(
    f"#!{sys.executable}\n"
    "import argparse\nfrom http.server import BaseHTTPRequestHandler,ThreadingHTTPServer\n"
    "parser=argparse.ArgumentParser();parser.add_argument('--listen');args,_=parser.parse_known_args()\n"
    "class Handler(BaseHTTPRequestHandler):\n"
    " def log_message(self,*_): pass\n"
    " def do_GET(self):\n"
    "  self.send_response(200);self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'{}')\n"
    "host,port=args.listen.split(':');ThreadingHTTPServer((host,int(port)),Handler).serve_forever()\n")
binary.chmod(0o700)
hub = Hub(args.run_dir / "run", control_port=args.port, proxy_port=0, server_port=0, publisher_port=0,
          keep=True, identity="controlled-launcher-" + args.failure)
hub.candidate._binary = binary
health = hub.server._await_health


def await_health(_fresh):
    health(False)
    print("controlled primary failure retained", flush=True)
    (args.run_dir / "health-ready").touch()
    if args.failure == "blocked-startup":
        # Intentional cancellation-resistant startup to exercise external deadline ownership checks.
        threading.Event().wait()


hub.server._await_health = await_health
if args.failure == "retention":
    def failed_capture(*_arguments, **_options):
        raise OSError("controlled retention failure")
    from hub import control as control_module
    control_module.retain = failed_capture


def stop(*_):
    def finish():
        print("controlled primary failure retained", flush=True)
        hub.stop(primary_error="controlled primary failure retained")
    threading.Thread(target=finish).start()


signal.signal(signal.SIGTERM, stop)
hub.launch()
try:
    hub.control.serve_forever(poll_interval=0.05)
finally:
    hub.stop(primary_error="controlled primary failure retained")
