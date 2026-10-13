"""Bounded shutdown of the hub's own HTTP workers and connections."""
from __future__ import annotations

import socket
import threading
import time
from http.server import ThreadingHTTPServer


class OwnedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args, **kwargs) -> None:
        self.workers = set()
        self.requests = set()
        self.worker_lock = threading.Lock()
        self.serving = threading.Event()
        self.quiescing = False
        super().__init__(*args, **kwargs)

    def serve_forever(self, *args, **kwargs) -> None:
        self.serving.set()
        try:
            super().serve_forever(*args, **kwargs)
        finally:
            self.serving.clear()

    def process_request(self, request, client_address) -> None:
        with self.worker_lock:
            if self.quiescing:
                self.shutdown_request(request)
                return
            self.requests.add(request)
            worker = threading.Thread(target=self.process_request_thread, args=(request, client_address), daemon=True)
            self.workers.add(worker)
            worker.start()

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.worker_lock:
                self.requests.discard(request)
                self.workers.discard(threading.current_thread())

    def begin_quiesce(self) -> None:
        """Refuse arrivals and cancel socket reads before component/job cancellation and worker joins."""
        with self.worker_lock:
            self.quiescing = True
            requests = list(self.requests)
        if self.serving.is_set():
            self.shutdown()
        self.server_close()
        for request in requests:
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def quiesce(self, timeout: float = 30) -> None:
        self.begin_quiesce()
        deadline = time.monotonic() + timeout
        with self.worker_lock:
            workers = list(self.workers)
        for worker in workers:
            if worker is not threading.current_thread():
                worker.join(max(0, deadline - time.monotonic()))
        alive = [worker.name for worker in workers if worker.is_alive() and worker is not threading.current_thread()]
        if alive:
            raise RuntimeError(f"hub HTTP workers did not exit: {alive}")
