#!/usr/bin/env bash
set -euo pipefail

readonly POLICY_NAMES=("idp-workload-baseline" "idp-tenant-identity")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly POLICY_FILE="${SCRIPT_DIR}/tenant-workload-policy.yaml"
readonly BINDING_FILE="${SCRIPT_DIR}/tenant-workload-binding.yaml"
rollout_complete=false

warn_on_incomplete_rollout() {
  if [[ "${rollout_complete}" != true ]]; then
    echo "Admission rollout did not complete; deny bindings remain absent or in audit-only mode." >&2
  fi
}
trap warn_on_incomplete_rollout EXIT

# Existing deny bindings must not evaluate a replacement policy until the API
# server has compiled and type-checked it. Move only this installer's bindings
# to audit mode during an update; a first install has no binding yet.
for policy_name in "${POLICY_NAMES[@]}"; do
  if kubectl get validatingadmissionpolicybinding "${policy_name}" >/dev/null 2>&1; then
    kubectl patch validatingadmissionpolicybinding "${policy_name}" \
      --type=merge \
      --field-manager=idp-platform \
      --patch='{"spec":{"validationActions":["Audit"]}}'
  fi
done

kubectl apply --server-side --field-manager=idp-platform -f "${POLICY_FILE}"

for policy_name in "${POLICY_NAMES[@]}"; do
  deadline=$((SECONDS + 60))
  policy_ready=false
  while ((SECONDS < deadline)); do
    policy_json="$(kubectl get validatingadmissionpolicy "${policy_name}" -o json)"

    set +e
    diagnostic="$(printf '%s' "${policy_json}" | python3 -c '
import json
import sys

policy = json.load(sys.stdin)
status = policy.get("status", {})
if (
    status.get("observedGeneration") != policy["metadata"].get("generation")
    or "typeChecking" not in status
):
    raise SystemExit(1)

warnings = status["typeChecking"].get("expressionWarnings", [])
if warnings:
    print(json.dumps(warnings, indent=2))
    raise SystemExit(2)
')"
    check_status=$?
    set -e

    case "${check_status}" in
      0)
        policy_ready=true
        break
        ;;
      1)
        sleep 2
        ;;
      2)
        echo "Admission policy CEL type-check failed for ${policy_name}:" >&2
        echo "${diagnostic}" >&2
        exit 1
        ;;
      *)
        echo "Unable to inspect admission policy type-check status for ${policy_name}." >&2
        exit "${check_status}"
        ;;
    esac
  done

  if [[ "${policy_ready}" != true ]]; then
    echo "Timed out waiting for admission policy CEL type-checking for ${policy_name}." >&2
    exit 1
  fi
done

kubectl apply --server-side --field-manager=idp-platform -f "${BINDING_FILE}"
rollout_complete=true
for policy_name in "${POLICY_NAMES[@]}"; do
  kubectl get validatingadmissionpolicy "${policy_name}"
  kubectl get validatingadmissionpolicybinding "${policy_name}"
done
