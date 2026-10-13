"""The release candidate (PROTOCOL §16): the pinned server with the pinned web client, built by
`Tools/ntp-server.sh --with-web` from archived copies; the web copy the
web actor runs from come from the same script. Builds are cached under the checkout's `.work/`.
"""

from __future__ import annotations

import subprocess
import threading
import os
from pathlib import Path

from .evidence import private_directory
from .processes import finish_process, owned_popen

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "Tools" / "ntp-server.sh"


def pinned(name: str) -> str:
    for line in (ROOT / "TestSupport" / "Server" / name).read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            return line.strip()
    raise RuntimeError(f"no commit in TestSupport/Server/{name}")


class Candidate:
    def __init__(self, logs: Path | None = None) -> None:
        self.lock = threading.Lock()
        self.server_commit = pinned("server-version.txt")
        self.web_commit = pinned("web-version.txt")
        self._binary: Path | None = None
        self.logs = logs
        self.build_lock = threading.Lock()
        self.builds: list[subprocess.Popen] = []
        self.active_builds: set[subprocess.Popen] = set()
        self.closing = False

    def _run(self, *arguments: str) -> Path:
        with self.build_lock:
            if self.closing:
                raise RuntimeError("candidate builds cancelled by shutdown")
            log = None
            if self.logs:
                private_directory(self.logs)
                path = self.logs / f"build-{len(self.builds) + 1}.log"
                log = open(path, "a")
                os.chmod(path, 0o600)
            try:
                built = owned_popen(["/bin/zsh", str(SCRIPT), *arguments], stdout=subprocess.PIPE,
                                    stderr=log or subprocess.PIPE, text=True)
                self.builds.append(built)
                self.active_builds.add(built)
            finally:
                if log:
                    log.close()
        finalized = False
        try:
            output, error = built.communicate()
            finish_process(built, timeout=0, graceful=True)
            finalized = True
        finally:
            if finalized:
                with self.build_lock:
                    self.active_builds.discard(built)
        if built.returncode != 0:
            detail = error or (path.read_text(errors="replace") if self.logs else "")
            raise RuntimeError("Tools/ntp-server.sh failed: " + detail.strip()[-2000:])
        return Path(output.strip().splitlines()[-1])

    def shutdown(self) -> list[dict]:
        with self.build_lock:
            self.closing = True
            active = list(self.active_builds)
        return [finish_process(process) for process in active]

    def binary(self) -> Path:
        """The release candidate's server binary."""
        with self.lock:
            if self._binary is None:
                self._binary = self._run("--with-web")
            return self._binary

    def source(self) -> Path:
        """The archived server source of the candidate (the witness runs there)."""
        return self.binary().parent / "src"

    def web_copy(self) -> Path:
        with self.lock:
            return self._run("--web-copy")

    def go(self) -> str:
        import os
        if os.environ.get("NTP_GO"):
            return os.environ["NTP_GO"]
        top = Path(str(ROOT).split("/.work/", 1)[0])
        checkout = Path(os.environ.get("NTP_SERVER_CHECKOUT") or top.parent / "NotTennaPod-Server")
        return str(checkout / ".work" / "toolchains" / "go" / "bin" / "go")

    def describe(self) -> dict:
        return {"server_commit": self.server_commit, "web_commit": self.web_commit,
                "binary": str(self._binary) if self._binary else None}
