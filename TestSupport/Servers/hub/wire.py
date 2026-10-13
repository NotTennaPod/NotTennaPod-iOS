"""R, the thin wire client (PROTOCOL §16, rows 25 and 35): an installation that declares no queue capability and
sends no queue bundles. It only listens: it reads the account's records (an attach snapshot, then pulls) to name an
episode, and pushes listening facts (`session.start`, `session.checkpoint`, `session.end`) as a phone records them,
so the server resolves the queue add on start and the removal on completion. It is evidence of server behaviour
with real receiving clients (P and W), never of a client lacking the queue; none ships.

It talks to the server through the proxy, like every client. Tokens are kept in memory and never logged.
"""

from __future__ import annotations

import base64
import http.client
import json
import threading
import time
import urllib.error
import urllib.request
import uuid

CAPABILITIES = ["favorites", "history", "inbox", "statistics"]


class WireError(RuntimeError):
    def __init__(self, status: int, body: dict) -> None:
        super().__init__(f"HTTP {status}: {body.get('error', body)}")
        self.status = status
        self.body = body


def canonical(value) -> bytes:
    """RFC 8785 for the values R sends (objects, arrays, strings, integers, booleans)."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


class WireClient:
    def __init__(self, events, name: str, base: str) -> None:
        self.events = events
        self.name = name
        self.base = base
        self.lock = threading.RLock()
        self.install_id = str(uuid.uuid4())
        self.nonce = str(uuid.uuid4())
        self.token: str | None = None
        self.account: dict = {}
        self.cursor: str | None = None
        self.records: dict[tuple[str, str, str], dict | None] = {}
        self.author_seq = 1
        self.previous: str | None = None
        self.next_slot = 1
        self.acked = 0
        self.pending: list[dict] = []
        self.sessions: dict[str, dict] = {}
        self.clock_offset_ms = 0

    # ---- transport

    def send(self, method: str, path: str, body: dict | None = None, timeout: float = 60) -> dict:
        data = canonical(body) if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Accept", "application/json")
        request.add_header("NotTennaPod-Protocol", "1")
        request.add_header("User-Agent", "NotTennaPod-R/1 (acceptance hub)")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                return json.loads(answer.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                body = json.loads(error.read() or b"{}")
            except ValueError:
                body = {}
            raise WireError(error.code, body) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
            raise WireError(0, {"error": "unreachable", "detail": str(error)}) from None

    # ---- account

    def login(self, username: str, password: str, capabilities: list[str] | None = None) -> dict:
        with self.lock:
            answer = self.send("POST", "/v1/auth/device", {
                "username": username, "password": password, "install_id": self.install_id, "instance_nonce": self.nonce,
                "device": {"name": f"R {self.name} (acceptance wire client)", "platform": "android",
                           "app_version": "hub-r/1", "capabilities": sorted(capabilities if capabilities is not None else CAPABILITIES)}})
            self.token = answer["token"]
            self.account = {"account_id": answer["account"]["account_id"], "username": answer["account"].get("username")}
            self.events.emit("r", "login", client=self.name, install_id=self.install_id, username=username)
            self.attach()
            return self.describe()

    def attach(self) -> None:
        """The attach snapshot: every record, and the head as the cursor."""
        page = None
        while True:
            body = {"mode": "attach", "install_id": self.install_id, "acked_install_seq": self.acked}
            if page:
                body["page"] = page
            answer = self.send("POST", "/v1/snapshot", body)
            for item in answer.get("items") or []:
                if "record" in item:
                    self._record(item["record"])
            if answer.get("has_more"):
                page = answer["next"]
                continue
            self.cursor = answer["head"]
            return

    def _record(self, record: dict) -> None:
        key = (record["entity"], record["id"], record["field_group"])
        self.records[key] = None if record.get("tombstone") else record.get("value")

    def pull(self) -> int:
        """Pulls to the head; returns the number of commits read."""
        with self.lock:
            commits = 0
            page = None
            parts: list[bytes] = []
            while True:
                body = {"cursor": self.cursor, "install_id": self.install_id, "acked_install_seq": self.acked}
                if page:
                    body["page"] = page
                answer = self.send("POST", "/v1/pull", body)
                for item in answer.get("items") or []:
                    commit = item.get("commit")
                    if commit is None and "commit_part" in item:  # a framed commit, joined from its parts
                        part = item["commit_part"]
                        data = part["data"]
                        parts.append(base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)))
                        if part["part_index"] + 1 < part["part_count"]:
                            continue
                        commit, parts = json.loads(b"".join(parts)), []
                    if commit is None:
                        continue
                    commits += 1
                    for record in commit.get("records") or []:
                        self._record(record)
                if answer.get("has_more"):
                    page = answer["next"]
                    continue
                self.cursor = answer.get("head", self.cursor)
                return commits

    # ---- what R knows

    def value(self, entity: str, id: str, group: str) -> dict | None:
        return self.records.get((entity, id, group))

    def episodes(self) -> list[dict]:
        found = []
        for (entity, id, group), value in self.records.items():
            if entity == "episode" and group == "identity" and value:
                metadata = self.value("episode", id, "metadata") or {}
                membership = self.value("episode", id, "queue_membership") or {}
                position = self.value("episode", id, "position") or {}
                found.append({"episode_id": id, "podcast_id": value.get("podcast_id"), "title": metadata.get("title"),
                              "in_queue": bool(membership.get("in_queue")),
                              "play_state": (self.value("episode", id, "play_state") or {}).get("play_state"),
                              "position": position.get("position", 0), "claim_id": position.get("claim_id"),
                              "played_ms": (self.value("episode", id, "played_time") or {}).get("played_ms", 0)})
        return sorted(found, key=lambda episode: episode["episode_id"])

    def find(self, episode: str | None = None, title: str | None = None) -> str:
        matches = [found["episode_id"] for found in self.episodes()
                   if (episode and found["episode_id"] == episode) or (title and found["title"] == title)]
        if len(matches) != 1:
            raise KeyError(f"{len(matches)} episodes match {episode or title!r}")
        return matches[0]

    def reference(self, episode: str) -> tuple[dict, dict]:
        identity = self.value("episode", episode, "identity")
        if not identity:
            raise KeyError(f"no identity record for {episode}")
        podcast = identity["podcast_id"]
        generation = (self.value("podcast", podcast, "subscription") or {}).get("generation_id")
        if not generation:
            raise KeyError(f"no live generation for {podcast}")
        ref = {"episode_id": episode, "podcast_id": podcast, "generation_id": generation,
               "occurrence": identity.get("occurrence") or {"k": "none", "v": ""}}
        return ref, {"entity": "episode", "id": episode, "generation": generation}

    def describe(self) -> dict:
        return {"client": self.name, "install_id": self.install_id, "account": self.account, "signed_in": self.token is not None,
                "capabilities_queue": False, "facts_pending": len(self.pending), "next_slot": self.next_slot,
                "acked": self.acked, "sessions": list(self.sessions)}

    # ---- facts

    def _fact(self, type: str, target: dict, payload: dict) -> dict:
        op = str(uuid.uuid4())
        fact = {"op_id": op, "author_id": self.install_id, "author_seq": self.author_seq,
                "dependencies": [self.previous] if self.previous else [], "type": type, "type_version": 1,
                "client_time": int(time.time() * 1000) + self.clock_offset_ms, "targets": [target], "payload": payload}
        if self.previous:
            fact["previous_op_id"] = self.previous
        self.author_seq += 1
        self.previous = op
        self.pending.append({"install_seq": self.next_slot, "fact": fact})
        self.next_slot += 1
        return fact

    def push(self, secrets: list[dict] | None = None) -> list[dict]:
        """Pushes every pending fact; returns their results (status and receipt outcome)."""
        with self.lock:
            if not self.pending:
                return []
            answer = self.send("POST", "/v1/push", {"cursor": self.cursor, "install_id": self.install_id,
                                                   "acked_install_seq": self.acked, "operations": self.pending,
                                                   **({"secrets": secrets} if secrets else {})})
            results = []
            by_slot = {operation["install_seq"]: operation["fact"] for operation in self.pending}
            for result in answer.get("results") or []:
                slot, status = result.get("install_seq"), result.get("status")
                receipt = result.get("receipt") or {}
                fact = by_slot.get(slot, {})
                results.append({"install_seq": slot, "status": status, "op_id": fact.get("op_id"), "type": fact.get("type"),
                                "outcome": receipt.get("outcome"), "reason": receipt.get("reason")})
                if status in ("accepted", "duplicate"):
                    self.acked = max(self.acked, slot)
            self.pending = [operation for operation in self.pending if operation["install_seq"] > self.acked]
            for result in results:
                self.events.emit("r", "pushed", client=self.name, **{key: value for key, value in result.items() if key != "op_id"})
            return results

    def play(self, episode: str, position_ms: int = 0) -> dict:
        """Starts listening: `session.start`. The server resolves the queue add for a client without the queue."""
        with self.lock:
            ref, target = self.reference(episode)
            session, baseline = str(uuid.uuid4()), str(uuid.uuid4())
            fact = self._fact("session.start", target, {"episode": ref, "session_id": session, "start_position": position_ms,
                                                        "activity": True, "baseline": baseline})
            self.sessions[session] = {"episode": episode, "ordinal": 0, "start_op": fact["op_id"], "start": position_ms}
            results = self.push()
            return {"session": session, "results": results}

    def checkpoint(self, session: str, position_ms: int) -> dict:
        with self.lock:
            state = self.sessions[session]
            ref, target = self.reference(state["episode"])
            state["ordinal"] += 1
            self._fact("session.checkpoint", target, {"episode": ref, "session_id": session, "ordinal": state["ordinal"],
                                                      "position": position_ms,
                                                      "contribution": max(0, position_ms - state["start"]), "activity": True})
            return {"session": session, "results": self.push()}

    def end(self, session: str, position_ms: int, completed: bool) -> dict:
        """Ends listening: completion removes the episode from the queue, as the server resolves it."""
        with self.lock:
            state = self.sessions.pop(session)
            ref, target = self.reference(state["episode"])
            state["ordinal"] += 1
            self._fact("session.end", target, {"episode": ref, "session_id": session, "ordinal": state["ordinal"],
                                               "position": position_ms, "contribution": max(0, position_ms - state["start"]),
                                               "activity": True, "reason": "ended" if completed else "switched",
                                               "completed": completed, "threshold_ms": 30000, "remove_from_queue": False,
                                               "history": True})
            return {"session": session, "results": self.push()}
