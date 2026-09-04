.PHONY: help confirm-destroy verify-aws-destroy-target test-destroy-guard infra-up infra-down kubeconfig cluster-up storage-up tenant-up admission-up eso-up crossplane-config crossplane-packages crossplane-definitions crossplane-compositions argocd-up kyverno-up monitoring-up portal-up cluster-down up down status validate

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

TF_DIR := infrastructure/terraform/stacks/prod
TEAMS := identity-platform platform-engineering data-platform
CLUSTER_NAME ?= idp-prod

# Destructive targets are intentionally pinned to the reviewed production
# identity. GNU Make command-line assignments cannot override these values.
override DESTROY_AWS_ACCOUNT_ID := 851236938302
override DESTROY_AWS_REGION := us-east-1
override DESTROY_CLUSTER_NAME := idp-prod
override DESTROY_CONFIRMATION := $(DESTROY_AWS_ACCOUNT_ID)/$(DESTROY_AWS_REGION)/$(DESTROY_CLUSTER_NAME)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  up                  Deploy all AWS infra and K8s platform configs"
	@echo "  portal-up           Launch the local read-only catalog on http://localhost:3000"
	@echo "  monitoring-up       Deploy Prometheus, Grafana, and Kubecost FinOps stack"
	@echo "  storage-up          Apply the encrypted gp3 StorageClass"
	@echo "  tenant-up           Create and configure host-cluster tenant namespaces"
	@echo "  admission-up        Enforce native Kubernetes workload policies"
	@echo "  crossplane-config   Install providers, XRDs, then Compositions in order"
	@echo "  down                Destroy the environment (requires CONFIRM_DESTROY=$(DESTROY_CONFIRMATION))"
	@echo "  status              Show cluster nodes and autoscaling status"
	@echo "  test-destroy-guard  Run mocked destructive-target safety tests"
	@echo "  validate            Validate Terraform configurations"

# Deploy AWS infrastructure (VPC, Subnets, EKS)
infra-up:
	cd $(TF_DIR)/network && terraform init && terraform apply -auto-approve
	cd $(TF_DIR)/eks && terraform init && terraform apply -auto-approve

# Require the full reviewed account/region/cluster identity. Read the value from
# the recipe environment so shell metacharacters in user input are not expanded.
confirm-destroy:
	@expected="$(DESTROY_CONFIRMATION)"; \
	if [ "$${CONFIRM_DESTROY:-}" != "$$expected" ]; then \
		echo "$(RED)Destructive operation blocked.$(NC)"; \
		echo "Run again with CONFIRM_DESTROY=$$expected after checking the active environment."; \
		exit 1; \
	fi

# Verify AWS credentials before Terraform can destroy either production root.
verify-aws-destroy-target: confirm-destroy
	@./platform/operations/verify-destroy-target.sh aws \
		"$(DESTROY_AWS_ACCOUNT_ID)" "$(DESTROY_AWS_REGION)" "$(DESTROY_CLUSTER_NAME)"

# Tear down EKS and network infrastructure only in the reviewed AWS account.
infra-down: verify-aws-destroy-target
	cd $(TF_DIR)/eks && TF_WORKSPACE=default terraform destroy -auto-approve \
		-var='aws_region=$(DESTROY_AWS_REGION)' -var='cluster_name=$(DESTROY_CLUSTER_NAME)'
	cd $(TF_DIR)/network && TF_WORKSPACE=default terraform destroy -auto-approve \
		-var='aws_region=$(DESTROY_AWS_REGION)' -var='cluster_name=$(DESTROY_CLUSTER_NAME)'

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
	kubectl apply -f platform/bootstrap/karpenter/
	$(MAKE) storage-up
	$(MAKE) eso-up
	$(MAKE) tenant-up
	$(MAKE) admission-up
	$(MAKE) crossplane-config
	$(MAKE) argocd-up

# Configure encrypted gp3 volumes before any optional stateful tenant services.
storage-up:
	kubectl apply -f platform/bootstrap/storage/gp3.yaml
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

# Configure Crossplane in dependency order. Sub-makes keep the phases sequential
# even when the top-level make command is invoked with parallel execution.
crossplane-config:
	$(MAKE) crossplane-packages
	$(MAKE) crossplane-definitions
	$(MAKE) crossplane-compositions

# Install the provider/function packages only after Crossplane's package CRDs
# are established, then wait for the AWS ClusterProviderConfig API before use.
crossplane-packages:
	@echo "$(GREEN)Configuring Crossplane Runtimes with dedicated IRSA roles...$(NC)"
	@set -eu; \
	for crd in \
		deploymentruntimeconfigs.pkg.crossplane.io \
		providers.pkg.crossplane.io \
		functions.pkg.crossplane.io \
		compositeresourcedefinitions.apiextensions.crossplane.io \
		compositions.apiextensions.crossplane.io \
		compositionrevisions.apiextensions.crossplane.io \
		managedresourceactivationpolicies.apiextensions.crossplane.io; do \
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
		< infrastructure/crossplane/packages/deployment-runtime-config.yaml | kubectl apply -f -
	kubectl apply -f infrastructure/crossplane/packages/managed-resource-activation-policy.yaml
	kubectl apply -f infrastructure/crossplane/packages/providers.yaml
	@set -eu; \
	for provider in provider-aws-s3 provider-aws-rds provider-aws-elasticache provider-aws-ec2; do \
		kubectl wait --for=condition=Installed "provider.pkg.crossplane.io/$$provider" --timeout=600s; \
		kubectl wait --for=condition=Healthy "provider.pkg.crossplane.io/$$provider" --timeout=600s; \
	done
	kubectl wait --for=condition=Installed function.pkg.crossplane.io/function-python --timeout=600s
	kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-python --timeout=600s
	kubectl wait --for=condition=Healthy managedresourceactivationpolicy/idp-aws-resources --timeout=300s
	@set -eu; \
	for crd in \
		buckets.s3.aws.m.upbound.io \
		instances.ec2.aws.m.upbound.io \
		securitygroups.ec2.aws.m.upbound.io \
		securitygrouprules.ec2.aws.m.upbound.io \
		instances.rds.aws.m.upbound.io \
		subnetgroups.rds.aws.m.upbound.io \
		replicationgroups.elasticache.aws.m.upbound.io \
		subnetgroups.elasticache.aws.m.upbound.io; do \
		kubectl wait --for=condition=Established "crd/$$crd" --timeout=300s; \
	done
	kubectl wait --for=condition=Established crd/clusterproviderconfigs.aws.m.upbound.io --timeout=300s
	kubectl apply -f infrastructure/crossplane/provider-configs/provider-config.yaml

# Install the direct namespaced v2 public APIs before their Compositions.
crossplane-definitions:
	@set -eu; \
	for legacy_xrd in xobjectbuckets.idp.io xserverinstances.idp.io xpostgressqlinstances.idp.io xredisinstances.idp.io; do \
		if kubectl get "xrd/$$legacy_xrd" >/dev/null 2>&1; then \
			echo "$(RED)Legacy XRD $$legacy_xrd detected; namespaced v2 requires a fresh install or a planned live migration.$(NC)"; \
			exit 1; \
		fi; \
	done
	kubectl apply -f infrastructure/crossplane/apis/definitions/
	@set -eu; \
	for xrd in objectbuckets.idp.io serverinstances.idp.io postgressqlinstances.idp.io redisinstances.idp.io; do \
		kubectl wait --for=condition=Established "xrd/$$xrd" --timeout=180s; \
	done
	@set -eu; \
	for crd in \
		objectbuckets.idp.io \
		serverinstances.idp.io \
		postgressqlinstances.idp.io \
		redisinstances.idp.io; do \
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
	for file in infrastructure/crossplane/apis/compositions/*.yaml; do \
		VPC_ID="$$vpc_id" PRIVATE_SUBNET_1="$$private_subnet_1" PRIVATE_SUBNET_2="$$private_subnet_2" \
			envsubst '$$VPC_ID $$PRIVATE_SUBNET_1 $$PRIVATE_SUBNET_2' < "$$file" > "$$render_dir/$$(basename "$$file")"; \
	done; \
	kubectl apply -f "$$render_dir/"
	@set -eu; \
	for composition in \
		objectbuckets.idp.io \
		serverinstances.idp.io \
		postgressqlinstances.idp.io \
		redisinstances.idp.io; do \
		revision="$$(python3 infrastructure/crossplane/scripts/find-matching-composition-revision.py \
			"$$composition" --timeout 120)"; \
		kubectl wait --for=condition=ValidPipeline \
			"compositionrevision.apiextensions.crossplane.io/$$revision" --timeout=180s; \
	done

# Configure ArgoCD and multi-tenant GitOps
argocd-up:
	@echo "$(GREEN)Installing ArgoCD...$(NC)"
	./platform/gitops/argocd/install/install.sh
	@echo "$(GREEN)Waiting for ArgoCD CRDs...$(NC)"
	kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=120s
	@echo "$(GREEN)Applying ArgoCD Projects and ApplicationSets...$(NC)"
	kubectl apply -f platform/gitops/argocd/projects/
	kubectl apply -f platform/gitops/argocd/applicationsets/

# Enforce policies that Kubernetes 1.36 supports natively. The installer waits
# for CEL type-checking before it enables the deny bindings.
admission-up:
	@echo "$(GREEN)Installing native Kubernetes admission policies...$(NC)"
	./platform/security/admission/install.sh

# Kyverno is intentionally not part of the bootstrap until an approved release
# supports Kubernetes 1.36. Keep this target fail-closed for explicit callers.
kyverno-up:
	@echo "$(RED)Kyverno is disabled: the pinned policy engine is not approved for Kubernetes 1.36.$(NC)"
	@echo "Use 'make admission-up' for the supported native controls."
	@exit 1

# Configure Prometheus, Grafana, and Kubecost Monitoring & FinOps
monitoring-up:
	@echo "$(GREEN)Installing Prometheus, Grafana, and Kubecost...$(NC)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update || true
	helm repo add kubecost https://kubecost.github.io/cost-analyzer/ --force-update || true
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring -f platform/observability/prometheus/values.yaml
	helm upgrade --install kubecost kubecost/cost-analyzer -n monitoring -f platform/observability/kubecost/values.yaml

# Launch the lightweight local catalog. This is not the Backstage backend.
portal-up:
	@echo "$(GREEN)Launching local read-only IDP catalog on http://localhost:3000...$(NC)"
	node platform/developer-portal/local-catalog/server.js

# Clean up shared platform components. The guard returns the exact kube-context
# it verified, and every delete stays pinned to that context. Tenant namespaces
# are preserved.
cluster-down: confirm-destroy
	@set -eu; \
	umask 077; \
	source_context="$$(kubectl config current-context)"; \
	kubeconfig_snapshot="$$(mktemp /tmp/idp-destroy-kubeconfig.XXXXXX)"; \
	trap 'rm -f "$$kubeconfig_snapshot"' EXIT; \
	trap 'exit 129' HUP; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	kubectl --context "$$source_context" config view --minify --raw --flatten > "$$kubeconfig_snapshot"; \
	context="$$(KUBECONFIG="$$kubeconfig_snapshot" ./platform/operations/verify-destroy-target.sh cluster \
		"$(DESTROY_AWS_ACCOUNT_ID)" "$(DESTROY_AWS_REGION)" "$(DESTROY_CLUSTER_NAME)")"; \
	KUBECONFIG="$$kubeconfig_snapshot" kubectl --context "$$context" delete namespace argocd monitoring external-secrets kyverno --ignore-not-found; \
	KUBECONFIG="$$kubeconfig_snapshot" kubectl --context "$$context" delete -f platform/bootstrap/karpenter/ --ignore-not-found

# Full environment bootstrap
up: infra-up cluster-up monitoring-up

# Full environment teardown. Each sub-target runs its own target-identity guard;
# sub-makes keep the order deterministic even with make -j.
down:
	$(MAKE) cluster-down
	$(MAKE) infra-down

# Exercise every destructive guard path with local mock binaries only.
test-destroy-guard:
	./platform/operations/tests/verify-destroy-target.sh

# View status of EKS nodes and Karpenter NodePools
status:
	@kubectl cluster-info 2>/dev/null || echo "$(RED)Cluster not reachable$(NC)"
	@kubectl get nodes -o wide 2>/dev/null || echo "$(RED)No nodes found$(NC)"
	@kubectl get nodepools 2>/dev/null || echo "$(RED)No NodePools found$(NC)"

# Validate Terraform formatting and syntax
validate:
	cd $(TF_DIR)/network && terraform init -backend=false && terraform validate
	cd $(TF_DIR)/eks && terraform init -backend=false && terraform validate
