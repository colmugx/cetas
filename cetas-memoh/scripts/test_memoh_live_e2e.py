#!/usr/bin/env python3
"""Unit tests for the live Memoh E2E harness helpers.

These tests only protect the harness implementation. They are not a substitute
for the real Memoh workspace E2E.
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("memoh_live_e2e.py")
SPEC = importlib.util.spec_from_file_location("memoh_live_e2e", SCRIPT)
memoh_live_e2e = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(memoh_live_e2e)


class RedactionTest(unittest.TestCase):
    def test_direct_token_is_redacted(self):
        secret = "top-secret-token"
        out = memoh_live_e2e.redact(
            f"request failed with token={secret}",
            secret,
        )
        self.assertNotIn(secret, out)
        self.assertIn("<redacted>", out)

    def test_bearer_authorization_is_redacted(self):
        secret = "bearer-secret"
        out = memoh_live_e2e.redact(
            f"Authorization: Bearer {secret}",
            "",
        )
        self.assertNotIn(secret, out)
        self.assertEqual(out, "Authorization: Bearer <redacted>")

    def test_json_secret_fields_are_redacted(self):
        secrets = {
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "X-Memoh-Session-Token": "session-secret",
            "Authorization": "Bearer nested-secret",
        }
        text = (
            '{"access_token":"access-secret",'
            '"refresh_token":"refresh-secret",'
            '"X-Memoh-Session-Token":"session-secret",'
            '"Authorization":"Bearer nested-secret"}'
        )
        out = memoh_live_e2e.redact(text, "")
        for secret in secrets.values():
            self.assertNotIn(secret, out)
        self.assertEqual(out.count("<redacted>"), len(secrets))


class CapabilityTest(unittest.TestCase):
    def _status(self):
        return {
            "runtime_id": "runtime-1",
            "agent_id": "acp",
            "models": {
                "supported": True,
                "current_model_id": "model-a",
                "available_models": [
                    {"id": "model-a", "name": "Model A"},
                    {"id": "model-b", "name": "Model B"},
                ],
            },
            "reasoning": {
                "supported": True,
                "current_effort": "low",
                "available_efforts": [
                    {"id": "low", "name": "Low"},
                    {"id": "high", "name": "High"},
                ],
            },
        }

    def test_valid_runtime_capabilities_pass(self):
        memoh_live_e2e.assert_capabilities(self._status())

    def test_non_acp_runtime_is_rejected(self):
        status = self._status()
        status["agent_id"] = "other"
        with self.assertRaises(memoh_live_e2e.PreflightError):
            memoh_live_e2e.assert_capabilities(status)

    def test_empty_model_catalog_is_rejected(self):
        status = self._status()
        status["models"]["available_models"] = []
        with self.assertRaises(memoh_live_e2e.PreflightError):
            memoh_live_e2e.assert_capabilities(status)

    def test_missing_reasoning_capability_is_rejected(self):
        status = self._status()
        status["reasoning"]["supported"] = False
        with self.assertRaises(memoh_live_e2e.PreflightError):
            memoh_live_e2e.assert_capabilities(status)


class SelectionTest(unittest.TestCase):
    def test_choose_value_prefers_different_option(self):
        selected = memoh_live_e2e.choose_value(
            "model-a",
            [{"id": "model-a"}, {"id": "model-b"}],
        )
        self.assertEqual(selected, "model-b")

    def test_choose_value_reuses_only_option(self):
        selected = memoh_live_e2e.choose_value(
            "only",
            [{"id": "only"}],
        )
        self.assertEqual(selected, "only")

    def test_choose_value_rejects_empty_options(self):
        with self.assertRaises(memoh_live_e2e.PreflightError):
            memoh_live_e2e.choose_value("", [])


class ConcurrencySelectionTest(unittest.TestCase):
    def _status(self, models):
        return {
            "models": {
                "available_models": [{"id": model_id} for model_id in models]
            }
        }

    def test_distinct_shared_models_preserve_first_runtime_order(self):
        first, second = memoh_live_e2e.distinct_shared_model_ids(
            self._status(["model-b", "model-a", "model-c"]),
            self._status(["model-c", "model-b", "model-a"]),
        )
        self.assertEqual((first, second), ("model-b", "model-a"))

    def test_distinct_shared_models_require_two_shared_ids(self):
        with self.assertRaises(memoh_live_e2e.PreflightError):
            memoh_live_e2e.distinct_shared_model_ids(
                self._status(["model-a", "model-b"]),
                self._status(["model-a", "model-c"]),
            )


if __name__ == "__main__":
    unittest.main()
