#!/usr/bin/env python3
"""Create and apply an explicitly reviewed saved plan; never apply implicit changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROD_ACCOUNT = "851236938302"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest():
    result = hashlib.sha256()
    for path in sorted((ROOT / "infrastructure/terraform").rglob("*")):
        if path.is_file() and ".terraform" not in path.parts and path.suffix in (".tf", ".tfvars", ".hcl", ".tpl", ".json", ".yaml", ".yml"):
            result.update(str(path.relative_to(ROOT)).encode())
            result.update(path.read_bytes())
    return result.hexdigest()


def verify_review(plan, metadata, approval, current_source):
    actual = digest(plan)
    if approval != actual or metadata.get("sha256") != actual:
        raise ValueError("APPROVE_PLAN_SHA256 must match the exact saved plan you reviewed")
    if metadata.get("source_sha256") != current_source:
        raise ValueError("Terraform inputs changed after planning; generate and review a new plan")


def verify_backend(actual, expected, backend_type="s3"):
    config = actual.get("backend", {}).get("config", {})
    if actual.get("backend", {}).get("type") != backend_type:
        raise ValueError("Expected the reviewed " + backend_type + " backend")
    for key, value in expected.items():
        if config.get(key) != value:
            raise ValueError(f"Initialized backend does not match reviewed {key}")


def safe_environment():
    # Terraform injects these variables into CLI commands, including -destroy.
    # A saved plan must be created only with the arguments reviewed here.
    return {key: value for key, value in os.environ.items() if not key.startswith("TF_CLI_ARGS")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "apply"])
    parser.add_argument("--stack", choices=["state", "network", "eks", "controllers"], required=True)
    parser.add_argument("--destroy", action="store_true")
    parser.add_argument("--environment", choices=["prod", "staging", "dev"], default="prod")
    parser.add_argument("--account", default=PROD_ACCOUNT)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--cluster", default="idp-prod")
    parser.add_argument("--backend-bucket", default="amr-tf-state-2026-851236938302-us-east-1-an")
    parser.add_argument("--backend-region", default="us-east-1")
    args = parser.parse_args()
    for name, pattern in {"environment": r"[a-z][a-z0-9-]{0,20}", "account": r"[0-9]{12}",
                          "region": r"[a-z]{2}-[a-z]+-[0-9]+", "cluster": r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}"}.items():
        if not re.fullmatch(pattern, getattr(args, name)):
            parser.error(f"Invalid {name}")
    if args.environment == "prod" and (args.account, args.region, args.cluster) != (PROD_ACCOUNT, "us-east-1", "idp-prod"):
        parser.error("Production identity is review-pinned")
    if args.environment == "prod" and (args.backend_bucket, args.backend_region) != ("amr-tf-state-2026-851236938302-us-east-1-an", "us-east-1"):
        parser.error("Production backend identity is review-pinned")
    if args.environment != "prod" and (args.account == PROD_ACCOUNT or args.cluster == "idp-prod"):
        parser.error("A sandbox must use a separate account and cluster identity")
    identity = f"{args.account}/{args.region}/{args.cluster}"
    if args.destroy and os.environ.get("CONFIRM_DESTROY") != identity:
        parser.error(f"Destroy planning and applying require CONFIRM_DESTROY={identity}")
    os.umask(0o077)
    env = {**safe_environment(), "TF_WORKSPACE": "default", "AWS_PAGER": ""}
    account = subprocess.check_output(["aws", "sts", "get-caller-identity", "--region", args.region, "--query", "Account", "--output", "text"], env=env, text=True).strip()
    if account != args.account:
        raise ValueError("Active AWS account differs from the reviewed target")
    directory = ROOT / "infrastructure/terraform/stacks/prod" / args.stack
    if args.stack == "state":
        directory = ROOT / "infrastructure/terraform/stacks/bootstrap/state"
    data_dir = ROOT / ".idp/terraform" / args.environment / args.stack
    data_dir.mkdir(parents=True, exist_ok=True)
    env["TF_DATA_DIR"] = str(data_dir)
    command = ["terraform", f"-chdir={directory}"]
    backend = {"bucket": args.backend_bucket, "key": f"{args.environment}/{args.stack}/terraform.tfstate", "region": args.backend_region,
               "allowed_account_ids": [args.account], "encrypt": True, "use_lockfile": True,
               "kms_key_id": f"arn:aws:kms:{args.backend_region}:{args.account}:alias/idp-terraform-state"}
    backend_type = "s3"
    if args.stack == "state":
        backend_type = "local"
        state_dir = ROOT / ".idp/state-bootstrap" / args.environment
        state_dir.mkdir(parents=True, exist_ok=True)
        backend = {"path": str(state_dir / "terraform.tfstate")}
    init = [*command, "init", "-input=false", "-lockfile=readonly"]
    init += [f"-backend-config={key}={json.dumps(value) if isinstance(value, (bool, list)) else value}" for key, value in backend.items()]
    subprocess.run(init, env=env, check=True)
    verify_backend(json.loads((data_dir / "terraform.tfstate").read_text()), backend, backend_type)
    mode = "destroy" if args.destroy else "apply"
    plan_dir = ROOT / ".idp/plans" / args.environment
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan = plan_dir / f"{args.stack}-{mode}.tfplan"
    meta = plan.with_suffix(".json")

    def state_identity():
        state = json.loads(subprocess.check_output([*command, "state", "pull"], env=env, text=True))
        if not state.get("lineage"):
            raise ValueError("Destroy requires an existing, identifiable state")
        return {"lineage": state["lineage"], "serial": state["serial"]}

    def verify_retained_inventory():
        if not args.destroy or args.stack != "network":
            return
        inventory = json.loads(subprocess.check_output([
            "aws", "resourcegroupstaggingapi", "get-resources", "--region", args.region,
            "--tag-filters", "Key=ManagedBy,Values=Crossplane-IDP", f"Key=Environment,Values={args.environment}",
            "--output", "json"], env=env, text=True))
        if not isinstance(inventory.get("ResourceTagMappingList"), list):
            raise ValueError("Retained-resource inventory returned no verifiable resource list")
        if inventory["ResourceTagMappingList"]:
            raise ValueError("Retained Crossplane resources still depend on this network")

    if args.action == "plan":
        state = state_identity() if args.destroy else None
        verify_retained_inventory()
        inputs = [f"-var=aws_account_id={args.account}",
                  f"-var=aws_region={args.backend_region if args.stack == 'state' else args.region}",
                  f"-var=environment={args.environment}"]
        if args.stack != "state":
            inputs.append(f"-var=cluster_name={args.cluster}")
        if args.stack in ("state", "eks"):
            inputs.append(f"-var=state_bucket_name={args.backend_bucket}")
        subprocess.run([*command, "plan", "-input=false", f"-out={plan}", *inputs,
                        *(["-destroy"] if args.destroy else [])], env=env, check=True)
        metadata = {"sha256": digest(plan), "source_sha256": source_digest(), "identity": identity,
                    "backend": backend, "backend_type": backend_type, "state": state, "mode": mode, "stack": args.stack}
        meta.write_text(json.dumps(metadata, indent=2) + "\n")
        subprocess.run([*command, "show", "-no-color", str(plan)], env=env, check=True)
        print(f"Review the plan above. Apply with APPROVE_PLAN_SHA256={metadata['sha256']} and the same target arguments.")
    else:
        metadata = json.loads(meta.read_text())
        verify_review(plan, metadata, os.environ.get("APPROVE_PLAN_SHA256", ""), source_digest())
        if metadata["identity"] != identity or metadata["backend"] != backend or metadata["mode"] != mode or metadata["stack"] != args.stack:
            raise ValueError("Saved plan belongs to a different target")
        if metadata.get("backend_type", "s3") != backend_type:
            raise ValueError("Saved plan uses a different backend type")
        if args.destroy and metadata["state"] != state_identity():
            raise ValueError("State lineage or serial changed; review a fresh destroy plan")
        verify_retained_inventory()
        subprocess.run([*command, "apply", "-input=false", str(plan)], env=env, check=True)
        plan.unlink()
        meta.unlink()


if __name__ == "__main__":
    main()
