#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

NAMESPACE="kyverno"
HELM_RELEASE="kyverno"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$(cd "${DIR}/../policies" && pwd)"

echo -e "${YELLOW}Deploying Kyverno Policy Engine...${NC}"
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update || true
helm repo update

kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install ${HELM_RELEASE} kyverno/kyverno \
  --namespace ${NAMESPACE} \
  --values "${DIR}/values.yaml"

echo -e "${YELLOW}Waiting for Kyverno CRDs to be established...${NC}"
kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=120s

echo -e "${YELLOW}Applying Kyverno Security Policies and Crossplane Guardrails...${NC}"
kubectl apply -k "${POLICIES_DIR}"

echo -e "${GREEN}Kyverno Policy Engine deployed and policies applied successfully!${NC}"
