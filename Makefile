.PHONY: help confirm-destroy infra-up infra-down kubeconfig cluster-up storage-up tenant-up vcluster-up vcluster-down eso-up crossplane-config crossplane-packages crossplane-definitions crossplane-compositions argocd-up kyverno-up monitoring-up portal-up cluster-down up down status validate

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

TF_DIR := infrastructure/terraform/environments/prod
TEAMS := team-alpha team-beta team-gamma
CLUSTER_NAME ?= idp-prod
VCLUSTER_CHART_VERSION := 0.36.1

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  up                  Deploy all AWS infra and K8s platform configs"
	@echo "  portal-up           Launch Backstage Developer Portal on http://localhost:3000"
	@echo "  monitoring-up       Deploy Prometheus, Grafana, and Kubecost FinOps stack"
	@echo "  storage-up          Apply the encrypted gp3 StorageClass"
	@echo "  tenant-up           Create and configure host-cluster tenant namespaces"
	@echo "  crossplane-config   Install providers, XRDs, then Compositions in order"
	@echo "  vcluster-up          Install an optional vCluster (requires TEAM=<approved-team>)"
	@echo "  vcluster-down        Uninstall one vCluster safely (requires TEAM=<approved-team>)"
	@echo "  down                Destroy the environment (requires CONFIRM_DESTROY=$(CLUSTER_NAME))"
	@echo "  status              Show cluster nodes and autoscaling status"
	@echo "  validate            Validate Terraform configurations"

# Deploy AWS infrastructure (VPC, Subnets, EKS)
infra-up:
	cd $(TF_DIR)/network && terraform init && terraform apply -auto-approve
	cd $(TF_DIR)/eks && terraform init && terraform apply -auto-approve

# Require the exact cluster name before any destructive platform teardown.
confirm-destroy:
	@if [ "$(CONFIRM_DESTROY)" != "$(CLUSTER_NAME)" ]; then \
		echo "$(RED)Destructive operation blocked.$(NC)"; \
		echo "Run again with CONFIRM_DESTROY=$(CLUSTER_NAME) after checking the active environment."; \
		exit 1; \
	fi

# Tear down EKS and network infrastructure
infra-down: confirm-destroy
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
	$(MAKE) storage-up
	$(MAKE) eso-up
	$(MAKE) tenant-up
	$(MAKE) crossplane-config
	$(MAKE) argocd-up
	$(MAKE) kyverno-up

# Configure encrypted gp3 volumes before any optional stateful tenant services.
storage-up:
	kubectl apply -f platform/storageclass.yaml
	kubectl get storageclass gp3

# Create tenant boundaries directly on the host EKS cluster.
tenant-up:
	kubectl apply -f tenants/namespaces/
	kubectl apply -f tenants/rbac/cluster-roles.yaml
	@set -eu; \
	roles="$$(cd $(TF_DIR)/eks && terraform output -json tenant_external_secrets_role_arns)"; \
	for team in $(TEAMS); do \
		kubectl apply -f tenants/base/ -n $$team; \
		role_arn="$$(echo "$$roles" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$$team")"; \
		EXTERNAL_SECRETS_ROLE_ARN="$$role_arn" envsubst '$$EXTERNAL_SECRETS_ROLE_ARN' \
			< tenants/templates/external-secrets-service-account.yaml.tpl | kubectl apply -n $$team -f -; \
		kubectl apply -f tenants/rbac/bindings/$$team.yaml; \
	done

# Install a vCluster only when a team explicitly needs an isolated Kubernetes API.
vcluster-up:
	@if [ -z "$(TEAM)" ]; then \
		echo "$(RED)TEAM is required. Example: make vcluster-up TEAM=team-alpha$(NC)"; \
		exit 1; \
	fi
	@case " $(TEAMS) " in *" $(TEAM) "*) ;; *) \
		echo "$(RED)Unknown TEAM '$(TEAM)'. Allowed values: $(TEAMS)$(NC)"; \
		exit 1; \
	esac
	@cluster="$$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"; \
	case "$$cluster" in *"$(CLUSTER_NAME)"*) ;; *) \
		echo "$(RED)Refusing to install against context '$$cluster'; expected cluster $(CLUSTER_NAME).$(NC)"; \
		exit 1; \
	esac
	@kubectl get namespace "$(TEAM)" >/dev/null
	@kubectl get storageclass gp3 >/dev/null
	helm repo add loft-sh https://charts.loft.sh --force-update
	helm repo update loft-sh
	helm upgrade --install "$(TEAM)" loft-sh/vcluster \
		--version "$(VCLUSTER_CHART_VERSION)" \
		--namespace "$(TEAM)" \
		--wait --atomic \
		-f platform/vcluster/base/values.yaml \
		-f "platform/vcluster/teams/$(TEAM).yaml"

# Remove one optional vCluster without deleting its host namespace or PVCs.
vcluster-down:
	@if [ -z "$(TEAM)" ]; then \
		echo "$(RED)TEAM is required. Example: make vcluster-down TEAM=team-alpha$(NC)"; \
		exit 1; \
	fi
	@case " $(TEAMS) " in *" $(TEAM) "*) ;; *) \
		echo "$(RED)Unknown TEAM '$(TEAM)'. Allowed values: $(TEAMS)$(NC)"; \
		exit 1; \
	esac
	@cluster="$$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"; \
	case "$$cluster" in *"$(CLUSTER_NAME)"*) ;; *) \
		echo "$(RED)Refusing to uninstall against context '$$cluster'; expected cluster $(CLUSTER_NAME).$(NC)"; \
		exit 1; \
	esac
	helm status "$(TEAM)" --namespace "$(TEAM)" >/dev/null
	helm uninstall "$(TEAM)" --namespace "$(TEAM)" --keep-history

# Configure Crossplane in dependency order. Sub-makes keep the phases sequential
# even when the top-level make command is invoked with parallel execution.
crossplane-config:
	$(MAKE) crossplane-packages
	$(MAKE) crossplane-definitions
	$(MAKE) crossplane-compositions

# Install the provider/function packages only after Crossplane's package CRDs
# are established, then wait for the AWS ProviderConfig API before using it.
crossplane-packages:
	@echo "$(GREEN)Configuring Crossplane Runtimes with dedicated IRSA roles...$(NC)"
	@set -eu; \
	for crd in \
		deploymentruntimeconfigs.pkg.crossplane.io \
		providers.pkg.crossplane.io \
		functions.pkg.crossplane.io \
		compositeresourcedefinitions.apiextensions.crossplane.io \
		compositions.apiextensions.crossplane.io \
		compositionrevisions.apiextensions.crossplane.io; do \
		kubectl wait --for=condition=Established "crd/$$crd" --timeout=180s; \
	done
	@set -eu; \
	role_arns="$$(cd $(TF_DIR)/eks && terraform output -json crossplane_provider_role_arns)"; \
	s3_role_arn="$$(printf '%s' "$$role_arns" | python3 -c 'import json, sys; print(json.load(sys.stdin)["s3"])')"; \
	rds_role_arn="$$(printf '%s' "$$role_arns" | python3 -c 'import json, sys; print(json.load(sys.stdin)["rds"])')"; \
	elasticache_role_arn="$$(printf '%s' "$$role_arns" | python3 -c 'import json, sys; print(json.load(sys.stdin)["elasticache"])')"; \
	ec2_role_arn="$$(printf '%s' "$$role_arns" | python3 -c 'import json, sys; print(json.load(sys.stdin)["ec2"])')"; \
	CROSSPLANE_S3_ROLE_ARN="$$s3_role_arn" \
	CROSSPLANE_RDS_ROLE_ARN="$$rds_role_arn" \
	CROSSPLANE_ELASTICACHE_ROLE_ARN="$$elasticache_role_arn" \
	CROSSPLANE_EC2_ROLE_ARN="$$ec2_role_arn" \
	envsubst '$$CROSSPLANE_S3_ROLE_ARN $$CROSSPLANE_RDS_ROLE_ARN $$CROSSPLANE_ELASTICACHE_ROLE_ARN $$CROSSPLANE_EC2_ROLE_ARN' \
		< infrastructure/crossplane/providers/deployment-runtime-config.yaml | kubectl apply -f -
	kubectl apply -f infrastructure/crossplane/providers/providers.yaml
	@set -eu; \
	for provider in provider-aws-s3 provider-aws-rds provider-aws-elasticache provider-aws-ec2; do \
		kubectl wait --for=condition=Installed "provider.pkg.crossplane.io/$$provider" --timeout=600s; \
		kubectl wait --for=condition=Healthy "provider.pkg.crossplane.io/$$provider" --timeout=600s; \
	done
	kubectl wait --for=condition=Installed function.pkg.crossplane.io/function-python --timeout=600s
	kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-python --timeout=600s
	kubectl wait --for=condition=Established crd/providerconfigs.aws.upbound.io --timeout=300s
	kubectl apply -f infrastructure/crossplane/providers/provider-config.yaml

# Install the public APIs before their Compositions. These legacy XRDs still
# offer claims; the namespaced v2 API migration is intentionally a later step.
crossplane-definitions:
	kubectl apply -f infrastructure/crossplane/definitions/
	@set -eu; \
	for xrd in \
		xobjectbuckets.idp.io \
		xserverinstances.idp.io \
		xpostgressqlinstances.idp.io \
		xredisinstances.idp.io; do \
		kubectl wait --for=condition=Established "xrd/$$xrd" --timeout=180s; \
		kubectl wait --for=condition=Offered "xrd/$$xrd" --timeout=180s; \
	done
	@set -eu; \
	for crd in \
		xobjectbuckets.idp.io objectbuckets.idp.io \
		xserverinstances.idp.io serverinstances.idp.io \
		xpostgressqlinstances.idp.io postgressqlinstances.idp.io \
		xredisinstances.idp.io redisinstances.idp.io; do \
		kubectl wait --for=condition=Established "crd/$$crd" --timeout=180s; \
	done

# Render environment-specific values only after the XRD APIs exist, apply the
# Compositions, and verify the newest generated revisions have valid pipelines.
crossplane-compositions:
	@echo "$(GREEN)Fetching VPC/Subnet IDs from Terraform...$(NC)"
	@set -eu; \
	vpc_id="$$(cd $(TF_DIR)/network && terraform output -raw vpc_id)"; \
	private_subnets="$$(cd $(TF_DIR)/network && terraform output -json private_subnet_ids)"; \
	private_subnet_1="$$(printf '%s' "$$private_subnets" | python3 -c 'import json, sys; subnets = json.load(sys.stdin); assert len(subnets) >= 2, "at least two private subnets are required"; print(subnets[0])')"; \
	private_subnet_2="$$(printf '%s' "$$private_subnets" | python3 -c 'import json, sys; subnets = json.load(sys.stdin); assert len(subnets) >= 2, "at least two private subnets are required"; print(subnets[1])')"; \
	echo "$(GREEN)VPC: $$vpc_id | Subnets: $$private_subnet_1, $$private_subnet_2$(NC)"; \
	render_dir="$$(mktemp -d /tmp/idp-crossplane.XXXXXX)"; \
	trap 'rm -rf "$$render_dir"' EXIT HUP INT TERM; \
	for file in infrastructure/crossplane/compositions/*.yaml; do \
		VPC_ID="$$vpc_id" PRIVATE_SUBNET_1="$$private_subnet_1" PRIVATE_SUBNET_2="$$private_subnet_2" \
			envsubst '$$VPC_ID $$PRIVATE_SUBNET_1 $$PRIVATE_SUBNET_2' < "$$file" > "$$render_dir/$$(basename "$$file")"; \
	done; \
	kubectl apply -f "$$render_dir/"
	@set -eu; \
	for composition in \
		xobjectbuckets.idp.io \
		xserverinstances.idp.io \
		xpostgressqlinstances.idp.io \
		xredisinstances.idp.io; do \
		revision="$$(python3 infrastructure/crossplane/scripts/find-matching-composition-revision.py \
			"$$composition" --timeout 120)"; \
		kubectl wait --for=condition=ValidPipeline \
			"compositionrevision.apiextensions.crossplane.io/$$revision" --timeout=180s; \
	done

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

# Clean up shared platform components. Tenant namespaces and optional vClusters are preserved.
cluster-down: confirm-destroy
	kubectl delete namespace argocd monitoring external-secrets kyverno --ignore-not-found
	kubectl delete -f platform/karpenter/ --ignore-not-found

# Full environment bootstrap
up: infra-up cluster-up monitoring-up

# Full environment teardown. Sub-makes keep the order deterministic even with make -j.
down: confirm-destroy
	$(MAKE) cluster-down
	$(MAKE) infra-down

# View status of EKS nodes and Karpenter NodePools
status:
	@kubectl cluster-info 2>/dev/null || echo "$(RED)Cluster not reachable$(NC)"
	@kubectl get nodes -o wide 2>/dev/null || echo "$(RED)No nodes found$(NC)"
	@kubectl get nodepools 2>/dev/null || echo "$(RED)No NodePools found$(NC)"

# Validate Terraform formatting and syntax
validate:
	cd $(TF_DIR)/network && terraform init -backend=false && terraform validate
	cd $(TF_DIR)/eks && terraform init -backend=false && terraform validate
