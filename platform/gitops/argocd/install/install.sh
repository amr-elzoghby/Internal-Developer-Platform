#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

NAMESPACE="argocd"
HELM_RELEASE="argocd"
CHART_VERSION="10.1.4"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

extra_values=()
if [[ -n "${ARGOCD_SSO_VALUES_FILE:-}" ]]; then
  python3 "${DIR}/validate-values.py" "${DIR}/values.yaml" "${ARGOCD_SSO_VALUES_FILE}"
  extra_values+=(--values "${ARGOCD_SSO_VALUES_FILE}")
else
  python3 "${DIR}/validate-values.py" "${DIR}/values.yaml"
fi

echo -e "${YELLOW}Deploying ArgoCD...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "${HELM_RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --atomic \
  --wait \
  --timeout 10m \
  --values "${DIR}/values.yaml" \
  "${extra_values[@]}"

for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=180s
done
kubectl wait --for=condition=Available deployment --all --namespace "${NAMESPACE}" --timeout=5m
kubectl rollout status statefulset/argocd-application-controller --namespace "${NAMESPACE}" --timeout=5m

echo -e "${GREEN}ArgoCD deployed successfully!${NC}"
if [[ -z "${ARGOCD_SSO_VALUES_FILE:-}" ]]; then
  echo "Private bootstrap access: kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8080:443"
  echo -e "Get bootstrap admin password via: kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
fi
