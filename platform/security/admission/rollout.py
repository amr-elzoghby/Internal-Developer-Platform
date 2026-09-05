#!/usr/bin/env python3
"""Compile versioned admission policies before atomically adding Deny bindings."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

import yaml

HERE = Path(__file__).resolve().parent
LABEL = "platform.idp.io/admission-owner"


def kubectl(*args, payload=None):
    result = subprocess.run(["kubectl", *args], input=payload, text=True,
                            capture_output=True, check=True)
    return result.stdout


def apply(objects):
    kubectl("apply", "--server-side", "--field-manager=idp-platform", "-f", "-",
            payload=json.dumps({"apiVersion": "v1", "kind": "List", "items": objects}))


def rollout():
    policies = list(yaml.safe_load_all((HERE / "tenant-workload-policy.yaml").read_text()))
    bindings = list(yaml.safe_load_all((HERE / "tenant-workload-binding.yaml").read_text()))
    revision = hashlib.sha256(json.dumps([policies, bindings], sort_keys=True).encode()).hexdigest()[:12]
    names = {p["metadata"]["name"]: p["metadata"]["name"] + "-" + revision for p in policies}
    for obj in policies + bindings:
        obj["metadata"]["labels"] = {LABEL: "installer"}
        obj["metadata"]["name"] += "-" + revision
    for binding in bindings:
        binding["spec"]["policyName"] = names[binding["spec"]["policyName"]]
        assert "Deny" in binding["spec"]["validationActions"]
    apply(policies)
    for policy in policies:
        deadline = time.monotonic() + 90
        while True:
            observed = json.loads(kubectl("get", "validatingadmissionpolicy", policy["metadata"]["name"], "-o", "json"))
            status = observed.get("status", {})
            if status.get("observedGeneration") == observed["metadata"].get("generation") and "typeChecking" in status:
                warnings = status["typeChecking"].get("expressionWarnings", [])
                if warnings:
                    raise RuntimeError(f"Candidate CEL failed type checking: {warnings}")
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("Admission type checking timed out; existing Deny policies remain active")
            time.sleep(2)
    # Adding the new bindings first preserves protection even on partial API
    # failures. Old and new rules overlap briefly; both enforce Deny.
    apply(bindings)
    current = {obj["metadata"]["name"] for obj in policies + bindings}
    for kind in ("validatingadmissionpolicybinding", "validatingadmissionpolicy"):
        owned = json.loads(kubectl("get", kind, "-l", f"{LABEL}=installer", "-o", "json"))
        for obj in owned.get("items", []):
            name = obj["metadata"]["name"]
            if name not in current:
                kubectl("delete", kind, name, "--ignore-not-found")
        # Retire only the two exact legacy resources after replacement is live.
        for legacy in names:
            kubectl("delete", kind, legacy, "--ignore-not-found")
    print(f"Admission revision {revision} enforces Deny.")


if __name__ == "__main__":
    rollout()
