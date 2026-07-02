.PHONY: help infra-up infra-down cluster-up cluster-down up down

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

TF_DIR := infrastructure/terraform/environments/prod

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Full Deployment:"
	@echo "  $(GREEN)up                  $(NC) Deploy everything (Infra + Cluster Config)"
	@echo "  $(GREEN)down                $(NC) Destroy everything safely"
	@echo ""
	@echo "Individual Steps:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -v 'up:\|down:' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'

# ─── Infrastructure (Terraform) ───────────────────────────────────────────────

infra-up: ## Provision AWS Infrastructure (Network → EKS)
	@echo "$(YELLOW)Provisioning Network Layer...$(NC)"
	cd $(TF_DIR)/network && terraform init && terraform apply -auto-approve
	@echo "$(YELLOW)Provisioning EKS Cluster...$(NC)"
	cd $(TF_DIR)/eks && terraform init && terraform apply -auto-approve
	@echo "$(GREEN)Infrastructure provisioning complete!$(NC)"

infra-down: ## Destroy AWS Infrastructure (EKS → Network)
	@echo "$(YELLOW)Destroying EKS Cluster...$(NC)"
	cd $(TF_DIR)/eks && terraform destroy -auto-approve
	@echo "$(YELLOW)Destroying Network Layer...$(NC)"
	cd $(TF_DIR)/network && terraform destroy -auto-approve
	@echo "$(GREEN)Infrastructure destroyed successfully!$(NC)"

# ─── Cluster Configuration ────────────────────────────────────────────────────

kubeconfig: ## Update local kubeconfig for the EKS cluster
	@echo "$(YELLOW)Updating kubeconfig...$(NC)"
	aws eks update-kubeconfig --name idp-prod --region us-east-1
	@echo "$(GREEN)kubeconfig updated!$(NC)"

cluster-up: kubeconfig ## Apply all K8s manifests (Tenants + Platform + Karpenter)
	@echo "$(YELLOW)Applying Karpenter NodePool & EC2NodeClass...$(NC)"
	kubectl apply -f platform/karpenter/
	@echo "$(GREEN)Cluster configuration complete!$(NC)"

cluster-down: ## Remove all K8s manifests
	@echo "$(YELLOW)Cleaning up Kubernetes resources...$(NC)"
	kubectl delete -f platform/karpenter/ --ignore-not-found
	@echo "$(GREEN)Cluster resources removed!$(NC)"

# ─── Full Deployment ──────────────────────────────────────────────────────────

up: infra-up cluster-up ## Full End-to-End Deployment
	@echo "$(GREEN)🚀 Internal Developer Platform is live!$(NC)"

down: cluster-down infra-down ## Destroy Everything
	@echo "$(GREEN)All resources destroyed. No charges will be incurred.$(NC)"

# ─── Utilities ────────────────────────────────────────────────────────────────

status: ## Show cluster and node status
	@echo "$(YELLOW)Cluster Info:$(NC)"
	@kubectl cluster-info 2>/dev/null || echo "$(RED)Cluster not reachable$(NC)"
	@echo ""
	@echo "$(YELLOW)Nodes:$(NC)"
	@kubectl get nodes -o wide 2>/dev/null || echo "$(RED)No nodes found$(NC)"
	@echo ""
	@echo "$(YELLOW)Karpenter NodePools:$(NC)"
	@kubectl get nodepools 2>/dev/null || echo "$(RED)No NodePools found$(NC)"

validate: ## Validate all Terraform configurations
	@echo "$(YELLOW)Validating Network module...$(NC)"
	cd $(TF_DIR)/network && terraform init -backend=false && terraform validate
	@echo "$(YELLOW)Validating EKS module...$(NC)"
	cd $(TF_DIR)/eks && terraform init -backend=false && terraform validate
	@echo "$(GREEN)All configurations valid!$(NC)"
