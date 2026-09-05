#!/usr/bin/env python3
"""Run a command against an independently verified, private EKS kubeconfig."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import re


def read_environment():
    # Terraform is the existing environment source of truth; do not maintain a
    # second configuration file that can drift from the actual EKS identity.
    root = os.environ.get("TF_DIR", "infrastructure/terraform/stacks/prod")
    result = subprocess.run(["terraform", f"-chdir={root}/eks", "output", "-json", "platform_context"],
                            check=True, capture_output=True, text=True)
    config = json.loads(result.stdout)
    for key, pattern in {"aws_account_id": r"[0-9]{12}", "aws_region": r"[a-z]{2}-[a-z]+-[0-9]+",
                         "cluster_name": r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}"}.items():
        if not re.fullmatch(pattern, str(config.get(key, ""))):
            raise ValueError(f"Missing or invalid Terraform platform_context field: {key}")
    return config


def aws_json(*args):
    result = subprocess.run(["aws", *args, "--output", "json"], check=True,
                            capture_output=True, text=True)
    return json.loads(result.stdout)


def kubeconfig(config):
    region = config["aws_region"]
    account = aws_json("sts", "get-caller-identity", "--region", region)["Account"]
    if account != config["aws_account_id"]:
        raise ValueError("Active AWS account does not match the reviewed environment")
    cluster = aws_json("eks", "describe-cluster", "--name", config["cluster_name"], "--region", region)["cluster"]
    arn = f"arn:aws:eks:{region}:{account}:cluster/{config['cluster_name']}"
    if cluster.get("arn") != arn or cluster.get("status") != "ACTIVE":
        raise ValueError("EKS ARN or status does not match the reviewed environment")
    endpoint = cluster.get("endpoint", "")
    ca = cluster.get("certificateAuthority", {}).get("data", "")
    if not endpoint.startswith("https://") or not ca:
        raise ValueError("EKS returned no verifiable TLS endpoint")
    return {"apiVersion": "v1", "kind": "Config", "current-context": arn,
            "clusters": [{"name": arn, "cluster": {"server": endpoint, "certificate-authority-data": ca}}],
            "contexts": [{"name": arn, "context": {"cluster": arn, "user": arn}}],
            "users": [{"name": arn, "user": {"exec": {
                "apiVersion": "client.authentication.k8s.io/v1beta1", "command": "aws",
                "args": ["eks", "get-token", "--cluster-name", config["cluster_name"], "--region", region],
                "interactiveMode": "Never"}}}]}


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: in-cluster.py COMMAND [ARG ...]")
    config = read_environment()
    snapshot = kubeconfig(config)
    with tempfile.TemporaryDirectory(prefix="idp-verified-") as directory:
        path = Path(directory) / "kubeconfig.json"
        path.write_text(json.dumps(snapshot))
        path.chmod(0o600)
        env = {**os.environ, "KUBECONFIG": str(path), "IDP_VERIFIED_KUBECONFIG": str(path), "AWS_PAGER": ""}
        subprocess.run(["kubectl", "get", "--raw=/readyz"], env=env, check=True)
        result = subprocess.run(sys.argv[1:], env=env, check=False)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
