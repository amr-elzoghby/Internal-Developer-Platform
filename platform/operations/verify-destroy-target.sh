#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Destructive operation blocked: %s\n' "$*" >&2
  exit 1
}

mode="${1:-}"
expected_account_id="${2:-}"
expected_region="${3:-}"
expected_cluster_name="${4:-}"

case "$mode" in
  aws | cluster) ;;
  *) fail "mode must be 'aws' or 'cluster'" ;;
esac

[[ "$expected_account_id" =~ ^[0-9]{12}$ ]] || fail "the reviewed AWS account ID is invalid"
[[ "$expected_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || fail "the reviewed AWS region is invalid"
[[ "$expected_cluster_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "the reviewed EKS cluster name is invalid"

expected_confirmation="${expected_account_id}/${expected_region}/${expected_cluster_name}"
[[ "${CONFIRM_DESTROY:-}" == "$expected_confirmation" ]] || fail "CONFIRM_DESTROY must equal ${expected_confirmation}"

command -v aws >/dev/null 2>&1 || fail "AWS CLI is not installed"
export AWS_PAGER=""

if ! actual_account_id="$(
  aws sts get-caller-identity \
    --region "$expected_region" \
    --query Account \
    --output text
)"; then
  fail "AWS caller identity could not be read"
fi

[[ "$actual_account_id" == "$expected_account_id" ]] || fail \
  "AWS account ${actual_account_id} does not match ${expected_account_id}"

if [[ "$mode" == "aws" ]]; then
  printf 'Verified AWS account %s for the destructive Terraform target.\n' "$actual_account_id" >&2
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed"

if ! cluster_identity="$(
  aws eks describe-cluster \
    --name "$expected_cluster_name" \
    --region "$expected_region" \
    --query 'cluster.[arn,endpoint,status,certificateAuthority.data]' \
    --output text
)"; then
  fail "EKS cluster identity could not be read"
fi

IFS=$'\t' read -r actual_cluster_arn actual_cluster_endpoint actual_cluster_status actual_cluster_ca <<< "$cluster_identity"
expected_cluster_arn="arn:aws:eks:${expected_region}:${expected_account_id}:cluster/${expected_cluster_name}"

[[ "$actual_cluster_arn" == "$expected_cluster_arn" ]] || fail \
  "EKS ARN ${actual_cluster_arn:-<empty>} does not match ${expected_cluster_arn}"
[[ "$actual_cluster_status" == "ACTIVE" ]] || fail \
  "EKS cluster ${expected_cluster_name} is not ACTIVE (status: ${actual_cluster_status:-<empty>})"
[[ -n "$actual_cluster_endpoint" && "$actual_cluster_endpoint" != "None" ]] || fail \
  "EKS returned no API endpoint"
[[ -n "$actual_cluster_ca" && "$actual_cluster_ca" != "None" ]] || fail \
  "EKS returned no certificate authority data"

if ! kube_context="$(kubectl config current-context)"; then
  fail "kubectl has no readable current context"
fi
[[ -n "$kube_context" ]] || fail "kubectl current context is empty"

if ! kube_endpoint="$(
  kubectl --context "$kube_context" config view --minify \
    -o 'jsonpath={.clusters[0].cluster.server}'
)"; then
  fail "the Kubernetes API endpoint could not be read from context ${kube_context}"
fi
[[ "$kube_endpoint" == "$actual_cluster_endpoint" ]] || fail \
  "kubectl context ${kube_context} points to ${kube_endpoint:-<empty>}, not ${actual_cluster_endpoint}"

if ! kube_insecure="$(
  kubectl --context "$kube_context" config view --minify \
    -o 'jsonpath={.clusters[0].cluster.insecure-skip-tls-verify}'
)"; then
  fail "the TLS settings could not be read from context ${kube_context}"
fi
[[ "$kube_insecure" != "true" ]] || fail \
  "kubectl context ${kube_context} disables TLS certificate verification"

if ! kube_ca="$(
  kubectl --context "$kube_context" config view --minify --raw \
    -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}'
)"; then
  fail "the certificate authority could not be read from context ${kube_context}"
fi
[[ "$kube_ca" == "$actual_cluster_ca" ]] || fail \
  "kubectl context ${kube_context} does not use the EKS cluster certificate authority"

kubectl --context "$kube_context" auth can-i delete namespaces --quiet >/dev/null || fail \
  "the current Kubernetes identity cannot delete namespaces"
kubectl --context "$kube_context" auth can-i delete nodepools.karpenter.sh --quiet >/dev/null || fail \
  "the current Kubernetes identity cannot delete Karpenter NodePools"
kubectl --context "$kube_context" auth can-i delete ec2nodeclasses.karpenter.k8s.aws --quiet >/dev/null || fail \
  "the current Kubernetes identity cannot delete Karpenter EC2NodeClasses"

printf 'Verified AWS account, EKS ARN, API endpoint, CA, status, and delete permissions for %s.\n' \
  "$kube_context" >&2
printf '%s\n' "$kube_context"
