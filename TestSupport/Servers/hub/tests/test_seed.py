"""Seed prerequisites fail on independently wrong secrets, empty receipts or missing listening effects."""
from __future__ import annotations

import copy
import unittest
from types import SimpleNamespace

from .test_lifecycle import IsolatedHubTestCase


class SyntheticClient:
    def __init__(self, fault=None):
        self.fault = fault
        self.stage = 0
        self.credentials = {}
        self.records = {}

    def login(self, *_):
        pass

    def episodes(self):
        contribution = 0 if self.stage < 2 else 2500 if self.stage == 2 else 3000
        if self.fault == "missing_effect":
            contribution = 0
        return [{"episode_id": "episode", "podcast_id": "podcast", "title": "Synthetic episode",
                 "in_queue": self.stage > 0, "played_ms": 7000 + contribution,
                 "position": 4500 if self.stage == 2 else 5000 if self.stage == 3 else 2000}]

    def value(self, entity, _id, group):
        if group == "subscription":
            return {"generation_id": "generation"}
        if group == "history":
            return {"generation_id": "generation", "time": 100 if self.stage == 0 or self.fault == "missing_history" else 200}

    def result(self, kind):
        return {"session": "session", "results": [] if self.fault == kind else [{"status": "accepted", "type": kind}]}

    def play(self, *_):
        self.stage = 1
        return self.result("session.start")

    def checkpoint(self, *_):
        self.stage = 2
        return self.result("session.checkpoint")

    def end(self, *_):
        self.stage = 3
        return self.result("session.end")

    def pull(self):
        pass

    def _fact(self, *_):
        pass

    def push(self, secrets):
        self.credentials = copy.deepcopy(secrets[0])
        return [{"status": "accepted"}]

    def send(self, *_):
        value = dict(self.credentials)
        if self.fault == "missing_password":
            value.pop("password")
        if self.fault == "changed_password":
            value["password"] = "wrong"
        return value


class SeedContractTests(unittest.TestCase):
    def seed(self, fault=None):
        class Controlled(IsolatedHubTestCase):
            def runTest(self):
                pass

        case = Controlled()
        client = SyntheticClient(fault)
        case.hub = SimpleNamespace(client=lambda _name: client)
        case.post = lambda *_: {"username": "synthetic", "account_id": "account", "import": {"status": "published"}}
        return case.seed_library()

    def test_independent_expected_seed_accepts_a_known_nonempty_control(self):
        seed = self.seed()
        self.assertEqual(seed["credentials"]["password"], "fixture-private-secret")

    def test_wrong_secret_readback_fails_before_freezing_continuity(self):
        for fault in ("missing_password", "changed_password"):
            with self.subTest(fault=fault), self.assertRaisesRegex(AssertionError, "seeded secret password"):
                self.seed(fault)

    def test_empty_listening_receipts_and_unchanged_values_cannot_become_a_baseline(self):
        for fault in ("session.start", "session.checkpoint", "session.end", "missing_effect", "missing_history"):
            with self.subTest(fault=fault), self.assertRaises(AssertionError):
                self.seed(fault)
