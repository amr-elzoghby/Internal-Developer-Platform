#!/usr/bin/env python3
"""Render bootstrap manifests from explicit, non-secret Terraform outputs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]


def output(stack, name):
    directory = Path(os.environ.get("TF_DIR", "infrastructure/terraform/stacks/prod")) / stack
    result = subprocess.run(["terraform", f"-chdir={directory}", "output", "-json", name],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def render_text(text, values):
    for name, value in values.items():
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_:/.,@=-]+", value):
            raise ValueError(f"Unsafe or missing bootstrap output: {name}")
        text = text.replace("${" + name + "}", value)
    unresolved = re.findall(r"\$\{[A-Z][A-Z0-9_]*\}", text)
    if unresolved:
        raise ValueError(f"Unresolved bootstrap values: {sorted(set(unresolved))}")
    return text


def composition_values():
    context = output("eks", "platform_context")
    private = output("network", "private_subnet_ids")
    data = output("network", "data_subnet_ids")
    if len(private) < 2 or len(data) < 2:
        raise ValueError("Crossplane needs two private worker subnets and two isolated data subnets")
    return {
        "VPC_ID": output("network", "vpc_id"),
        "PRIVATE_SUBNET_1": private[0], "PRIVATE_SUBNET_2": private[1],
        "DATA_SUBNET_1": data[0], "DATA_SUBNET_2": data[1],
        "AWS_REGION": context["aws_region"], "ENVIRONMENT": context["environment"],
        "RESOURCE_NAME_PREFIX": context["cluster_name"],
        "EKS_NODE_SECURITY_GROUP_ID": output("eks", "node_security_group_id"),
        "APPROVED_SERVER_AMI_ID": output("eks", "approved_server_ami_id"),
        "EC2_INSTANCE_PROFILE_NAME": output("eks", "ec2_instance_profile_name"),
        "RDS_MONITORING_ROLE_ARN": output("eks", "rds_monitoring_role_arn"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=["compositions"])
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    values = composition_values()
    rendered = {}
    for path in sorted((ROOT / "infrastructure/crossplane/apis/compositions").glob("*.yaml")):
        text = render_text(path.read_text(), values)
        list(yaml.safe_load_all(text))
        rendered[path.name] = text
    # Validate every output before producing any file that kubectl can apply.
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, text in rendered.items():
        (args.output_dir / name).write_text(text)
    print(f"Rendered {len(rendered)} {args.component}; contains infrastructure IDs, never secret values.")


if __name__ == "__main__":
    main()
