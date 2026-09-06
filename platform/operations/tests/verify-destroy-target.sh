#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
make_bin="$(command -v make)"
tmp_dir="$(mktemp -d)"
mock_bin="${tmp_dir}/bin"
mock_log="${tmp_dir}/calls.log"
test_output="${tmp_dir}/test-output.log"

cleanup() {
  [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$mock_bin"

cat >"${mock_bin}/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${MOCK_AWS_FAILURE:-0}" == "1" ]]; then
  exit 90
fi

case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    [[ "$*" == "sts get-caller-identity --region us-east-1 --query Account --output text" ]] || exit 91
    printf '%s\n' "$MOCK_ACCOUNT_ID"
    ;;
  "eks describe-cluster")
    [[ "${MOCK_EKS_FAILURE:-0}" == "0" ]] || exit 94
    [[ "$*" == "eks describe-cluster --name idp-prod --region us-east-1 --query cluster.[arn,endpoint,status,certificateAuthority.data] --output text" ]] || exit 92
    printf '%s\t%s\t%s\t%s\n' "$MOCK_CLUSTER_ARN" "$MOCK_CLUSTER_ENDPOINT" "$MOCK_CLUSTER_STATUS" "$MOCK_CLUSTER_CA"
    ;;
  *) exit 93 ;;
esac
MOCK_AWS

cat >"${mock_bin}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${MOCK_KUBECTL_FAILURE:-0}" == "1" ]]; then
  exit 80
fi

if [[ "$*" == "config current-context" ]]; then
  [[ -n "${MOCK_KUBE_CONTEXT:-}" ]] || exit 81
  printf '%s\n' "$MOCK_KUBE_CONTEXT"
  exit 0
fi

[[ "${1:-}" == "--context" && "${2:-}" == "$MOCK_KUBE_CONTEXT" ]] || exit 82
shift 2

case "$*" in
  "config view --minify -o jsonpath={.clusters[0].cluster.server}")
    printf '%s' "$MOCK_KUBE_ENDPOINT"
    ;;
  "config view --minify -o jsonpath={.clusters[0].cluster.insecure-skip-tls-verify}")
    printf '%s' "$MOCK_KUBE_INSECURE"
    ;;
  "config view --minify --raw -o jsonpath={.clusters[0].cluster.certificate-authority-data}")
    printf '%s' "$MOCK_KUBE_CA"
    ;;
  "config view --minify --raw --flatten")
    printf '%s\n' 'apiVersion: v1' 'kind: Config' "current-context: $MOCK_KUBE_CONTEXT"
    ;;
  "auth can-i delete deployments --all-namespaces --quiet" | \
  "auth can-i delete nodepools.karpenter.sh --quiet" | \
  "auth can-i delete ec2nodeclasses.karpenter.k8s.aws --quiet")
    [[ "$MOCK_CAN_DELETE" == "1" ]]
    ;;
  delete\ *)
    [[ "${KUBECONFIG:-}" == /tmp/idp-destroy-kubeconfig.* ]] || exit 84
    [[ -s "$KUBECONFIG" ]] || exit 85
    printf 'delete-kubeconfig %s\n' "$KUBECONFIG" >>"$MOCK_LOG"
    ;;
  *) exit 83 ;;
esac
MOCK_KUBECTL

cat >"${mock_bin}/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform cwd=%q' "$PWD" >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
[[ "${TF_WORKSPACE:-}" == "default" ]] || exit 69
[[ "$*" == "destroy -auto-approve -var=aws_region=us-east-1 -var=cluster_name=idp-prod" ]] || exit 70
MOCK_TERRAFORM

cat >"${mock_bin}/helm" <<'MOCK_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm' >>"$MOCK_LOG"
printf ' %q' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"
[[ "${KUBECONFIG:-}" == /tmp/idp-destroy-kubeconfig.* && -s "$KUBECONFIG" ]] || exit 75
[[ "$*" == *"--kube-context $MOCK_KUBE_CONTEXT"* ]] || exit 76
printf 'helm-kubeconfig %s\n' "$KUBECONFIG" >>"$MOCK_LOG"
[[ "${MOCK_HELM_FAILURE:-0}" == "0" ]] || exit 77
MOCK_HELM

chmod +x "${mock_bin}/aws" "${mock_bin}/kubectl" "${mock_bin}/terraform" "${mock_bin}/helm"

export PATH="${mock_bin}:/usr/bin:/bin"
export MOCK_LOG="$mock_log"
export AWS_EC2_METADATA_DISABLED=true
export AWS_ACCESS_KEY_ID=invalid
export AWS_SECRET_ACCESS_KEY=invalid
export KUBECONFIG="${tmp_dir}/empty-kubeconfig"
unset BASH_ENV ENV GNUMAKEFLAGS MAKEFLAGS MFLAGS MAKEFILES MAKEOVERRIDES

readonly correct_confirmation="851236938302/us-east-1/idp-prod"
readonly expected_arn="arn:aws:eks:us-east-1:851236938302:cluster/idp-prod"
readonly expected_endpoint="https://SAFE_ENDPOINT.us-east-1.eks.amazonaws.com"
readonly expected_ca="SAFE_CA_DATA"

reset_mocks() {
  : >"$mock_log"
  : >"$test_output"
  export MOCK_AWS_FAILURE=0
  export MOCK_EKS_FAILURE=0
  export MOCK_KUBECTL_FAILURE=0
  export MOCK_ACCOUNT_ID=851236938302
  export MOCK_CLUSTER_ARN="$expected_arn"
  export MOCK_CLUSTER_ENDPOINT="$expected_endpoint"
  export MOCK_CLUSTER_STATUS=ACTIVE
  export MOCK_CLUSTER_CA="$expected_ca"
  export MOCK_KUBE_CONTEXT="$expected_arn"
  export MOCK_KUBE_ENDPOINT="$expected_endpoint"
  export MOCK_KUBE_INSECURE=false
  export MOCK_KUBE_CA="$expected_ca"
  export MOCK_CAN_DELETE=1
  export MOCK_HELM_FAILURE=0
}

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  sed -n '1,120p' "$test_output" >&2
  sed -n '1,120p' "$mock_log" >&2
  exit 1
}

assert_no_destructive_calls() {
  if grep -Eq '^kubectl --context [^ ]+ delete |^terraform |^helm uninstall ' "$mock_log"; then
    fail_test "a destructive command ran after a failed guard"
  fi
}

expect_failure() {
  name="$1"
  target="$2"
  confirmation="$3"
  shift 3
  set +e
  CONFIRM_DESTROY="$confirmation" "$make_bin" --no-print-directory -C "$repo_root" "$target" "$@" \
    >"$test_output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail_test "$name unexpectedly succeeded"
  assert_no_destructive_calls
  printf 'PASS: %s\n' "$name"
}

expect_success() {
  name="$1"
  target="$2"
  shift 2
  if ! CONFIRM_DESTROY="$correct_confirmation" "$make_bin" --no-print-directory -C "$repo_root" "$target" "$@" \
    >"$test_output" 2>&1; then
    fail_test "$name failed"
  fi
  printf 'PASS: %s\n' "$name"
}

reset_mocks
expect_failure "legacy confirmation token is rejected" cluster-down idp-prod

reset_mocks
injection_marker="${tmp_dir}/confirmation-was-executed"
expect_failure "confirmation text is never evaluated by a shell" cluster-down \
  "\$(touch ${injection_marker})"
[[ ! -e "$injection_marker" ]] || fail_test "confirmation text executed as shell code"

reset_mocks
export MOCK_ACCOUNT_ID=000000000000
expect_failure "wrong AWS account is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_ACCOUNT_ID=000000000000
expect_failure "infra-down rejects the wrong AWS account" infra-down "$correct_confirmation"

reset_mocks
export MOCK_CLUSTER_ARN="arn:aws:eks:eu-west-1:851236938302:cluster/idp-prod"
expect_failure "wrong EKS ARN is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_CLUSTER_ARN="arn:aws:eks:us-east-1:851236938302:cluster/wrong-cluster"
expect_failure "wrong EKS cluster name is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_EKS_FAILURE=1
expect_failure "EKS identity lookup failure is fail-closed" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_CLUSTER_STATUS=UPDATING
expect_failure "non-active EKS cluster is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_KUBE_CONTEXT=
expect_failure "missing kube context is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_KUBE_ENDPOINT="https://WRONG_ENDPOINT.us-east-1.eks.amazonaws.com"
expect_failure "wrong kube endpoint is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_KUBE_INSECURE=true
expect_failure "insecure TLS context is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_KUBE_CA=WRONG_CA_DATA
expect_failure "wrong kube certificate authority is rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_CAN_DELETE=0
expect_failure "insufficient Kubernetes permissions are rejected" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_AWS_FAILURE=1
expect_failure "AWS API failure is fail-closed" cluster-down "$correct_confirmation"

reset_mocks
export MOCK_KUBECTL_FAILURE=1
expect_failure "Kubernetes API failure is fail-closed" cluster-down "$correct_confirmation"

reset_mocks
expect_success "cluster-down uses the verified context" cluster-down
[[ "$(grep -c '^helm uninstall ' "$mock_log")" -eq 6 ]] || fail_test "cluster-down did not uninstall all six releases"
[[ "$(awk '/^helm uninstall / { print $3 }' "$mock_log" | tr '\n' ' ')" == "argocd kubecost prometheus reloader external-secrets kyverno " ]] || \
  fail_test "Helm dependencies were uninstalled out of order"
if grep -Eq '^kubectl .*delete (namespace|pvc|persistentvolumeclaim|crd)' "$mock_log"; then
  fail_test "cluster-down deleted retained namespaces, data or CRDs"
fi
[[ "$(grep -c '^kubectl --context [^ ]* delete ' "$mock_log")" -eq 2 ]] || fail_test "cluster-down did not issue exactly two deletes"
if grep '^kubectl --context [^ ]* delete ' "$mock_log" | grep -Fv -- "--context $expected_arn" >/dev/null; then
  fail_test "a Kubernetes delete did not use the verified context"
fi
[[ "$(grep -c '^delete-kubeconfig /tmp/idp-destroy-kubeconfig\.' "$mock_log")" -eq 2 ]] || \
  fail_test "a Kubernetes delete did not use the private kubeconfig snapshot"
delete_snapshot="$(awk '/^delete-kubeconfig / { print $2 }' "$mock_log" | sort -u)"
[[ "$delete_snapshot" != *$'\n'* ]] || fail_test "Kubernetes deletes used more than one kubeconfig snapshot"
[[ ! -e "$delete_snapshot" ]] || fail_test "the kubeconfig snapshot was not removed after cluster-down"
[[ "$(awk '/^helm-kubeconfig / { print $2 }' "$mock_log" | sort -u)" == "$delete_snapshot" ]] || \
  fail_test "Helm did not use the verified kubeconfig snapshot"
[[ "$(awk '/^kubectl .*delete -f / { print $6 }' "$mock_log" | tr '\n' ' ')" == "platform/bootstrap/karpenter/node-pool.yaml platform/bootstrap/karpenter/node-class.yaml " ]] || \
  fail_test "Karpenter NodePools must drain before deleting the EC2NodeClass"

reset_mocks
export MOCK_HELM_FAILURE=1
if CONFIRM_DESTROY="$correct_confirmation" "$make_bin" --no-print-directory -C "$repo_root" cluster-down >"$test_output" 2>&1; then
  fail_test "cluster-down ignored Helm uninstall failure"
fi
[[ "$(grep -c '^helm uninstall ' "$mock_log")" -eq 1 ]] || fail_test "uninstall continued after Argo failure"
if grep -q '^kubectl --context [^ ]* delete ' "$mock_log"; then
  fail_test "Karpenter resources were removed before GitOps stopped"
fi
printf 'PASS: Helm uninstall failure stops teardown before dependencies are removed\n'

reset_mocks
expect_success "AWS guard verifies the reviewed account without changing infrastructure" verify-aws-destroy-target
assert_no_destructive_calls

reset_mocks
expect_failure "infra-down requires a saved reviewed destroy plan" infra-down "$correct_confirmation"

reset_mocks
export TF_VAR_aws_region=eu-west-1
export TF_VAR_cluster_name=wrong-cluster
expect_success "AWS identity guard ignores unrelated Terraform variable overrides" verify-aws-destroy-target
assert_no_destructive_calls
unset TF_VAR_aws_region TF_VAR_cluster_name

reset_mocks
expect_failure "full down cannot bypass per-layer plan review" down "$correct_confirmation"

reset_mocks
expect_success "reviewed target identity cannot be overridden from Make" cluster-down \
  DESTROY_AWS_ACCOUNT_ID=000000000000 DESTROY_AWS_REGION=eu-west-1 DESTROY_CLUSTER_NAME=wrong-cluster

reset_mocks
expect_failure "the confirmation target cannot be overridden from Make" cluster-down wrong-token \
  DESTROY_CONFIRMATION=wrong-token

printf 'All destructive-target safety tests passed.\n'
