#!/usr/bin/env python3
"""Check database policy decisions from `terraform test -json -verbose` output.

This deliberately supports only the policy constructs emitted by these policies;
it is not an AWS IAM simulator. Unsupported constructs fail the regression check.
"""
import fnmatch
import json
import sys


def items(value):
    return value if isinstance(value, list) else [value]


def conditions_match(conditions, context):
    results = []
    for operator, entries in conditions.items():
        for key, expected in entries.items():
            values = items(context[key]) if key in context else []
            expected = items(expected)
            if operator == "Null":
                result = (key not in context) == (expected[0] == "true")
            elif operator in ("StringEquals", "ForAnyValue:StringEquals"):
                result = any(value in expected for value in values)
            elif operator == "StringNotEquals":
                result = not any(value in expected for value in values)
            else:
                raise AssertionError(f"Unsupported condition: {operator}")
            results.append(result)
    return all(results)


def decision(policy, action, resource, context):
    allowed = False
    for statement in policy["Statement"]:
        unsupported = set(statement) - {"Sid", "Effect", "Action", "Resource", "NotResource", "Condition"}
        if unsupported:
            raise AssertionError(f"Unsupported statement: {unsupported}")
        if not any(fnmatch.fnmatchcase(action.lower(), pattern.lower()) for pattern in items(statement["Action"])):
            continue
        if "Resource" in statement and not any(fnmatch.fnmatchcase(resource, pattern) for pattern in items(statement["Resource"])):
            continue
        if "NotResource" in statement and any(fnmatch.fnmatchcase(resource, pattern) for pattern in items(statement["NotResource"])):
            continue
        if not conditions_match(statement.get("Condition", {}), context):
            continue
        if statement["Effect"] == "Deny":
            return False
        allowed = True
    return allowed


def check(plan):
    count = 0
    for service, kind, creates, modify, remove in [
        ("rds", "db", [("CreateDBInstance", "db"), ("CreateDBSubnetGroup", "subgrp")], "ModifyDBInstance", "RemoveTagsFromResource"),
        ("elasticache", "replicationgroup", [("CreateReplicationGroup", "replicationgroup"), ("CreateCacheSubnetGroup", "subnetgroup")], "ModifyReplicationGroup", "RemoveTagsFromResource"),
    ]:
        change = next(change for change in plan["resource_changes"] if change["address"] == f"aws_iam_policy.crossplane_{service}")
        policy = json.loads(change["change"]["after"]["policy"])
        prefix = f"arn:aws:{service}:us-east-1:123456789012:"
        arn = prefix + kind + ":idp-dev-crossplane-0123456789abcdef"
        request = {"aws:RequestTag/ManagedBy": "Crossplane-IDP", "aws:RequestTag/Environment": "dev"}
        owned = {"aws:ResourceTag/ManagedBy": "Crossplane-IDP", "aws:ResourceTag/Environment": "dev"}
        cases = [
            ("initial tags", "AddTagsToResource", arn, request, True),
            ("owned tags", "AddTagsToResource", arn, owned, True),
            ("owned update", modify, arn, owned, True),
            ("untagged update", modify, arn, request, False),
            ("outside namespace", "AddTagsToResource", prefix + kind + ":unrelated", request, False),
            ("outside namespace owned", modify, prefix + kind + ":unrelated", owned, False),
            ("cross account", "AddTagsToResource", arn.replace("123456789012", "999999999999"), request, False),
            ("cross region", "AddTagsToResource", arn.replace("us-east-1", "us-west-2"), request, False),
            ("ordinary tag removal", remove, arn, {**owned, "aws:TagKeys": ["Owner"]}, True),
        ]
        for tag, wrong in [("ManagedBy", "Other"), ("Environment", "prod")]:
            cases.extend([
                (f"missing request {tag}", "AddTagsToResource", arn, {k: v for k, v in request.items() if k != f"aws:RequestTag/{tag}"}, False),
                (f"wrong request {tag}", "AddTagsToResource", arn, {**request, f"aws:RequestTag/{tag}": wrong}, False),
                (f"foreign existing {tag}", "AddTagsToResource", arn, {**request, **owned, f"aws:ResourceTag/{tag}": wrong}, False),
                (f"partial existing {tag}", "AddTagsToResource", arn, {**request, f"aws:ResourceTag/{tag}": owned[f"aws:ResourceTag/{tag}"]}, False),
                (f"overwrite {tag}", "AddTagsToResource", arn, {**owned, f"aws:RequestTag/{tag}": wrong}, False),
                (f"remove {tag}", remove, arn, {**owned, "aws:TagKeys": [tag]}, False),
                (f"foreign update {tag}", modify, arn, {**owned, f"aws:ResourceTag/{tag}": wrong}, False),
            ])
        for create, resource_kind in creates:
            resource = prefix + resource_kind + ":idp-dev-crossplane-0123456789abcdef"
            cases.extend([
                (create, create, resource, request, True),
                (create + " missing tags", create, resource, {}, False),
                (create + " outside prefix", create, prefix + resource_kind + ":unrelated", request, False),
            ])
            for tag in ("ManagedBy", "Environment"):
                cases.append((create + " wrong " + tag, create, resource, {**request, f"aws:RequestTag/{tag}": "wrong"}, False))
        for dependency in (["pg", "og"] if service == "rds" else ["parametergroup"]):
            create = creates[0][0]
            resource = prefix + dependency + ":default.postgres16"
            cases.extend([
                ("default dependency without request tags", create, resource, {}, True),
                ("custom dependency denied", create, prefix + dependency + ":custom", {}, False),
                ("cannot tag default dependency", "AddTagsToResource", resource, request, False),
            ])
        for label, action, resource, context, expected in cases:
            actual = decision(policy, f"{service}:{action}", resource, context)
            assert actual == expected, f"{service}: {label}: expected {expected}, got {actual}"
            count += 1
    print(f"Database IAM regression: {count} policy decisions passed (local supported subset).")


if __name__ == "__main__":
    plans = [event["test_plan"] for event in map(json.loads, sys.stdin) if event.get("type") == "test_plan" and event.get("@testrun") == "crossplane_policy_contract"]
    assert len(plans) == 1, "Expected exactly one verbose crossplane_policy_contract plan"
    check(plans[0])
