#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

NAMESPACE="argocd"
HELM_RELEASE="argocd"
CHART_VERSION="10.1.4"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  --values "${DIR}/values.yaml"

kubectl wait --for=condition=Available deployment --all --namespace "${NAMESPACE}" --timeout=5m

echo -e "${GREEN}ArgoCD deployed successfully!${NC}"
echo -e "Get admin password via: kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
