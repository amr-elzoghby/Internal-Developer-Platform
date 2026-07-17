#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

NAMESPACE="argocd"
HELM_RELEASE="argocd"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${YELLOW}Deploying ArgoCD...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install ${HELM_RELEASE} argo/argo-cd \
  --namespace ${NAMESPACE} \
  --values "${DIR}/values.yaml"

echo -e "${GREEN}ArgoCD deployed successfully!${NC}"
echo -e "Get admin password via: kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
