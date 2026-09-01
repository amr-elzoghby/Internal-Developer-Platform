#!/usr/bin/env python3
"""Print the newest CompositionRevision that matches a Composition's current spec."""

import argparse
import json
import subprocess
import time


def kubectl_json(*args: str) -> dict:
    command = ["kubectl", *args, "--request-timeout=10s", "-o", "json"]
    return json.loads(subprocess.check_output(command, text=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("composition")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        composition = kubectl_json(
            "get",
            "composition.apiextensions.crossplane.io",
            args.composition,
        )
        revisions = kubectl_json(
            "get",
            "compositionrevision.apiextensions.crossplane.io",
            "-l",
            f"crossplane.io/composition-name={args.composition}",
        )

        matches = []
        for revision in revisions.get("items", []):
            revision_spec = dict(revision["spec"])
            revision_number = revision_spec.pop("revision")
            if revision_spec == composition["spec"]:
                matches.append((revision_number, revision["metadata"]["name"]))

        if matches:
            print(max(matches)[1])
            return

        time.sleep(2)

    raise SystemExit(
        f"No CompositionRevision matching {args.composition!r} appeared within "
        f"{args.timeout} seconds"
    )


if __name__ == "__main__":
    main()
