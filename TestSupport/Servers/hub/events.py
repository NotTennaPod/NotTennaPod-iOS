"""The hub's event log (PROTOCOL §16): what the proxy, the server's lifecycle, the publisher, the app bridge and
the web bridge observed, in the order the hub saw it. Faults fire on these events and journeys wait on them, with
limits; nothing waits for a time. Events never carry passwords, tokens or feed credentials.
"""

from __future__ import annotations

import fnmatch
import json
import threading
import time
from pathlib import Path
from typing import Any


def _text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value)


def matches(event: dict, filters: dict | None) -> bool:
    """Each filter names a member: equal (compared as text, so `status=503` matches 503), a glob (`*`, `?`), or any
    of a list."""
    for key, want in (filters or {}).items():
        if key not in event:
            return False
        have = _text(event[key])
        options = want if isinstance(want, list) else [want]
        if not any(fnmatch.fnmatchcase(have, _text(option)) if isinstance(option, str) and any(c in option for c in "*?[")
                   else have == _text(option) for option in options):
            return False
    return True


class EventLog:
    def __init__(self, path: Path | None = None) -> None:
        self._events: list[dict] = []
        self._condition = threading.Condition()
        self._origin = time.monotonic()
        self._file = None
        self._interrupted = False
        if path is not None:
            self.attach(path)

    def attach(self, path: Path) -> None:
        """Later events are also appended to `path`, one JSON object per line."""
        with self._condition:
            if self._file:
                self._file.close()
            path.parent.mkdir(parents=True, exist_ok=True)
            self._file = open(path, "a", encoding="utf-8")

    def close(self) -> None:
        with self._condition:
            if self._file:
                self._file.close()
                self._file = None

    def interrupt_waits(self) -> None:
        with self._condition:
            self._interrupted = True
            self._condition.notify_all()

    def emit(self, source: str, kind: str, **fields: Any) -> dict:
        with self._condition:
            event = {"seq": len(self._events) + 1, "t": round(time.monotonic() - self._origin, 3),
                     "wall_ms": int(time.time() * 1000), "source": source, "kind": kind}
            event.update({key: value for key, value in fields.items() if value is not None})
            self._events.append(event)
            if self._file:
                self._file.write(json.dumps(event, sort_keys=True) + "\n")
                self._file.flush()
            self._condition.notify_all()
            return event

    @property
    def last(self) -> int:
        with self._condition:
            return len(self._events)

    def select(self, after: int = 0, filters: dict | None = None, limit: int | None = None) -> list[dict]:
        with self._condition:
            found = [event for event in self._events[max(0, after):] if matches(event, filters)]
        return found[:limit] if limit else found

    def wait(self, after: int = 0, filters: dict | None = None, count: int = 1, timeout: float = 30.0) -> list[dict] | None:
        """The first `count` matching events after `after`, once there are that many; None when `timeout` runs out."""
        deadline = time.monotonic() + timeout
        with self._condition:
            while True:
                found = [event for event in self._events[max(0, after):] if matches(event, filters)]
                if len(found) >= count:
                    return found[:count]
                if self._interrupted:
                    return None
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self._condition.wait(left)
