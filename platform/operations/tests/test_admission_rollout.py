"""Fault injection verifies old Deny bindings survive compilation failures."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[2] / "security/admission/rollout.py"
SPEC = importlib.util.spec_from_file_location("rollout", PATH)
rollout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rollout)


class RolloutTest(unittest.TestCase):
    def exercise(self, warnings):
        calls = []

        def kubectl(*args, payload=None):
            calls.append((args, json.loads(payload) if payload else None))
            if args[0] == "get" and "-l" not in args:
                return json.dumps({"metadata": {"generation": 2}, "status": {
                    "observedGeneration": 2, "typeChecking": {"expressionWarnings": warnings}}})
            return '{"items": []}'

        with patch.object(rollout, "kubectl", kubectl):
            if warnings:
                with self.assertRaises(RuntimeError):
                    rollout.rollout()
            else:
                rollout.rollout()
        return calls

    def test_failed_compile_does_not_touch_bindings(self):
        calls = self.exercise([{"warning": "invalid CEL"}])
        self.assertFalse(any(args[0] in ("delete", "patch") for args, _ in calls))
        for _, payload in calls:
            if payload:
                self.assertTrue(all(x["kind"] == "ValidatingAdmissionPolicy" for x in payload["items"]))

    def test_bindings_enforce_before_old_bindings_are_deleted(self):
        calls = self.exercise([])
        binding_index = next(i for i, (_, p) in enumerate(calls) if p and p["items"][0]["kind"].endswith("Binding"))
        first_delete = next(i for i, (args, _) in enumerate(calls) if args[0] == "delete")
        self.assertLess(binding_index, first_delete)
        for binding in calls[binding_index][1]["items"]:
            self.assertIn("Deny", binding["spec"]["validationActions"])
            self.assertEqual(binding["metadata"]["name"], binding["spec"]["policyName"])


if __name__ == "__main__":
    unittest.main()
