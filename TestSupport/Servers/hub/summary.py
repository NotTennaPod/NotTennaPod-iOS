"""What Tools/acceptance.sh puts in a run's summary from the hub's event log.

    python3 TestSupport/Servers/hub/summary.py clock-offsets <events.jsonl>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def clock_offsets(events: list[dict]) -> list[str]:
    """Every clock offset the run used, the server's and each app launch's action clock, one line each, in order."""
    lines = []
    for event in events:
        if event.get("source") == "app" and event.get("kind") == "hello" and event.get("clock_offset_ms") is not None:
            lines.append(f"- event {event['seq']}: app launch (session {event.get('session')}, pid {event.get('pid')}, "
                         f"library {event.get('library')}) with action clock offset {event['clock_offset_ms']} ms")
        elif event.get("kind") in ("started", "clock") and ("clock_offset" in event or "offset" in event):
            lines.append(f"- event {event['seq']}: server {event['kind']} with offset "
                         f"{event.get('clock_offset', event.get('offset'))}")
    return lines


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] != "clock-offsets":
        sys.exit("usage: summary.py clock-offsets <events.jsonl>")
    events = [json.loads(line) for line in Path(sys.argv[2]).read_text().splitlines() if line.strip()]
    print("\n".join(clock_offsets(events)))


if __name__ == "__main__":
    main()
