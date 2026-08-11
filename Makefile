.PHONY: help infra-up infra-down kubeconfig cluster-up eso-up crossplane-config argocd-up kyverno-up monitoring-up portal-up cluster-down up down status validate

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

TF_DIR := infrastructure/terraform/environments/prod

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  up                  Deploy all AWS infra and K8s platform configs"
	@echo "  portal-up           Launch Backstage Developer Portal on http://localhost:3000"
	@echo "  monitoring-up       Deploy Prometheus, Grafana, and Kubecost FinOps stack"
	@echo "  down                Destroy all AWS and K8s platform resources"
	@echo "  status              Show cluster nodes and autoscaling status"
	@echo "  validate            Validate Terraform configurations"

# Deploy AWS infrastructure (VPC, Subnets, EKS)
infra-up:
	cd $(TF_DIR)/network && terraform init && terraform apply -auto-approve
	cd $(TF_DIR)/eks && terraform init && terraform apply -auto-approve

# Tear down EKS and network infrastructure
infra-down:
	cd $(TF_DIR)/eks && terraform destroy -auto-approve
	cd $(TF_DIR)/network && terraform destroy -auto-approve

# Update local Kubernetes kubeconfig credentials
kubeconfig:
	aws eks update-kubeconfig --name idp-prod --region us-east-1

# Deploy External Secrets Operator (ESO)
eso-up:
	@echo "$(GREEN)Installing External Secrets Operator...$(NC)"
	helm repo add external-secrets https://charts.external-secrets.io --force-update || true
	helm repo update
	kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets
	@echo "$(GREEN)Waiting for External Secrets CRDs...$(NC)"
	kubectl wait --for=condition=Established crd/secretstores.external-secrets.io --timeout=120s
	kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s

# Deploy Kubernetes platform components
cluster-up: kubeconfig
	kubectl apply -f platform/karpenter/
	$(MAKE) eso-up
	helm repo add loft-sh https://charts.loft.sh --force-update || true
	helm repo update
	@for team in team-alpha team-beta team-gamma; do \
		kubectl create namespace $$team --dry-run=client -o yaml | kubectl apply -f -; \
		kubectl apply -f tenants/base/ -n $$team; \
		helm upgrade --install $$team loft-sh/vcluster \
			--namespace $$team \
			-f platform/vcluster/base/values.yaml \
			-f platform/vcluster/teams/$$team.yaml; \
	done
	$(MAKE) crossplane-config
	$(MAKE) argocd-up
	$(MAKE) kyverno-up

# Configure Crossplane providers and custom Python compositions
crossplane-config:
	@echo "$(GREEN)Configuring Crossplane Runtime with IRSA Role...$(NC)"
	$(eval CROSSPLANE_ROLE_ARN := $(shell cd $(TF_DIR)/eks && terraform output -raw crossplane_provider_role_arn))
	@CROSSPLANE_ROLE_ARN=$(CROSSPLANE_ROLE_ARN) envsubst < infrastructure/crossplane/providers/deployment-runtime-config.yaml | kubectl apply -f -
	kubectl apply -f infrastructure/crossplane/providers/providers.yaml
	sleep 30
	kubectl wait --for=condition=Healthy provider.pkg.crossplane.io --all --timeout=300s
	kubectl wait --for=condition=Healthy function.pkg.crossplane.io --all --timeout=300s
	kubectl apply -f infrastructure/crossplane/providers/provider-config.yaml
	@echo "$(GREEN)Fetching VPC/Subnet IDs from Terraform...$(NC)"
	$(eval VPC_ID := $(shell cd $(TF_DIR)/network && terraform output -raw vpc_id))
	$(eval PRIVATE_SUBNETS := $(shell cd $(TF_DIR)/network && terraform output -json private_subnet_ids))
	$(eval PRIVATE_SUBNET_1 := $(shell echo '$(PRIVATE_SUBNETS)' | python3 -c "import sys, json; print(json.load(sys.stdin)[0])"))
	$(eval PRIVATE_SUBNET_2 := $(shell echo '$(PRIVATE_SUBNETS)' | python3 -c "import sys, json; print(json.load(sys.stdin)[1])"))
	@echo "$(GREEN)VPC: $(VPC_ID) | Subnets: $(PRIVATE_SUBNET_1), $(PRIVATE_SUBNET_2)$(NC)"
	@mkdir -p /tmp/crossplane-rendered
	@for f in infrastructure/crossplane/compositions/*.yaml; do \
		VPC_ID=$(VPC_ID) PRIVATE_SUBNET_1=$(PRIVATE_SUBNET_1) PRIVATE_SUBNET_2=$(PRIVATE_SUBNET_2) \
		envsubst '$$VPC_ID $$PRIVATE_SUBNET_1 $$PRIVATE_SUBNET_2' < $$f > /tmp/crossplane-rendered/$$(basename $$f); \
	done
	kubectl apply -f /tmp/crossplane-rendered/
	@rm -rf /tmp/crossplane-rendered

# Configure ArgoCD and multi-tenant GitOps
argocd-up:
	@echo "$(GREEN)Installing ArgoCD...$(NC)"
	./platform/argocd/install/install.sh
	@echo "$(GREEN)Waiting for ArgoCD CRDs...$(NC)"
	kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=120s
	@echo "$(GREEN)Applying ArgoCD Projects and ApplicationSets...$(NC)"
	kubectl apply -f platform/argocd/projects/
	kubectl apply -f platform/argocd/applicationsets/

# Configure Kyverno policy engine and security guardrails
kyverno-up:
	@echo "$(GREEN)Installing Kyverno Policy Engine...$(NC)"
	./platform/security/kyverno/install/install.sh

# Configure Prometheus, Grafana, and Kubecost Monitoring & FinOps
monitoring-up:
	@echo "$(GREEN)Installing Prometheus, Grafana, and Kubecost...$(NC)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update || true
	helm repo add kubecost https://kubecost.github.io/cost-analyzer/ --force-update || true
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring -f platform/monitoring/prometheus/values.yaml
	helm upgrade --install kubecost kubecost/cost-analyzer -n monitoring -f platform/monitoring/kubecost/values.yaml

# Launch Backstage Developer Portal
portal-up:
	@echo "$(GREEN)Launching Backstage Developer Portal on http://localhost:3000...$(NC)"
	node platform/backstage-portal/server.js

# Clean up namespaces and Helm releases from the cluster
cluster-down:
	@for team in team-alpha team-beta team-gamma; do \
		helm uninstall $$team --namespace $$team || true; \
	done
	kubectl delete namespace team-alpha team-beta team-gamma argocd monitoring external-secrets kyverno --ignore-not-found
	kubectl delete -f platform/karpenter/ --ignore-not-found

# Full environment bootstrap
up: infra-up cluster-up monitoring-up

# Full environment teardown
down: cluster-down infra-down

# View status of EKS nodes and Karpenter NodePools
status:
	@kubectl cluster-info 2>/dev/null || echo "$(RED)Cluster not reachable$(NC)"
	@kubectl get nodes -o wide 2>/dev/null || echo "$(RED)No nodes found$(NC)"
	@kubectl get nodepools 2>/dev/null || echo "$(RED)No NodePools found$(NC)"

# Validate Terraform formatting and syntax
validate:
	cd $(TF_DIR)/network && terraform init -backend=false && terraform validate
	cd $(TF_DIR)/eks && terraform init -backend=false && terraform validate

