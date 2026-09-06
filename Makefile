.PHONY: help confirm-destroy verify-aws-destroy-target test-destroy-guard infra-up infra-down kubeconfig cluster-up storage-up tenant-up admission-up eso-up crossplane-config crossplane-packages crossplane-definitions crossplane-compositions argocd-up kyverno-up monitoring-up portal-up cluster-down up down status validate

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

TF_DIR := infrastructure/terraform/stacks/prod
export TF_DIR
TEAMS := identity-platform platform-engineering data-platform
CLUSTER_NAME ?= idp-prod
AWS_REGION ?= us-east-1
override ESO_CHART_VERSION := 2.10.0
override KUBECOST_CHART_VERSION := 3.2.4
override PROMETHEUS_CHART_VERSION := 89.2.2
override RELOADER_CHART_VERSION := 2.2.16

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
	@echo "  up                  Bootstrap Kubernetes on reviewed AWS infrastructure"
	@echo "  infra-plan          Save a plan for STACK=state, network, eks, or controllers"
	@echo "  infra-apply         Apply STACK with APPROVE_PLAN_SHA256 after review"
	@echo "  platform-render     Render nonsecret bootstrap manifests for a Git review"
	@echo "  platform-bootstrap-up  Attach Argo CD to the merged bootstrap bundle"
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

# Infrastructure is reviewed one dependency layer at a time: state bootstrap,
# network, EKS, then controllers. An exact saved-plan approval is mandatory.
STACK ?=
PLAN_MODE ?= apply
export STACK PLAN_MODE
.PHONY: infra-plan infra-apply
infra-plan:
	@if [ "$$PLAN_MODE" = destroy ]; then python3 platform/operations/terraform-plan.py plan --stack "$$STACK" --destroy; elif [ "$$PLAN_MODE" = apply ]; then python3 platform/operations/terraform-plan.py plan --stack "$$STACK"; else echo 'PLAN_MODE must be apply or destroy' >&2; exit 2; fi
infra-apply:
	@if [ "$$PLAN_MODE" = destroy ]; then python3 platform/operations/terraform-plan.py apply --stack "$$STACK" --destroy; elif [ "$$PLAN_MODE" = apply ]; then python3 platform/operations/terraform-plan.py apply --stack "$$STACK"; else echo 'PLAN_MODE must be apply or destroy' >&2; exit 2; fi
infra-up: infra-apply

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

# Teardown requires separately reviewed plans in reverse dependency order.
infra-down: verify-aws-destroy-target
	@echo 'Create and review destroy plans with make infra-plan PLAN_MODE=destroy STACK=controllers, then eks, then network.' >&2
	@echo 'Apply each exact plan with make infra-apply PLAN_MODE=destroy STACK=... and APPROVE_PLAN_SHA256.' >&2
	@exit 2

# Update local Kubernetes kubeconfig credentials
kubeconfig:
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)

# Deploy External Secrets Operator (ESO)
_eso-up:
	@echo "$(GREEN)Installing External Secrets Operator...$(NC)"
	kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install external-secrets external-secrets \
		--repo https://charts.external-secrets.io \
		--version $(ESO_CHART_VERSION) \
		--namespace external-secrets \
		--set installCRDs=true \
		--atomic --wait --timeout 5m
	@echo "$(GREEN)Waiting for External Secrets CRDs...$(NC)"
	kubectl wait --for=condition=Established crd/secretstores.external-secrets.io --timeout=120s
	kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s
	@set -eu; \
	for crd in secretstores.external-secrets.io externalsecrets.external-secrets.io; do \
		served="$$(kubectl get crd "$$crd" -o jsonpath='{.spec.versions[?(@.name=="v1")].served}')"; \
		if [ "$$served" != "true" ]; then \
			echo "$(RED)External Secrets API v1 is not served by $$crd.$(NC)"; \
			exit 1; \
		fi; \
	done

# Deploy Kubernetes platform components
_cluster-up:
	@set -eu; rendered="$$(python3 platform/operations/render-platform.py --scope karpenter)"; printf '%s\n' "$$rendered" | kubectl apply -f -
	$(MAKE) storage-up
	$(MAKE) eso-up
	$(MAKE) tenant-up
	$(MAKE) reloader-up
	$(MAKE) admission-up
	$(MAKE) crossplane-config
	$(MAKE) argocd-up

# Configure encrypted gp3 volumes before any optional stateful tenant services.
.PHONY: reloader-up
_reloader-up:
	helm upgrade --install reloader reloader --repo https://stakater.github.io/stakater-charts --version $(RELOADER_CHART_VERSION) --namespace reloader --create-namespace --values platform/bootstrap/reloader/values.yaml --atomic --wait --timeout 5m

_storage-up:
	kubectl apply -f platform/bootstrap/storage/gp3.yaml
	kubectl get storageclass gp3

# Create tenant boundaries directly on the host EKS cluster.
_tenant-up:
	@set -eu; rendered="$$(python3 platform/operations/render-platform.py --scope tenants)"; printf '%s\n' "$$rendered" | kubectl apply -f -

# Configure Crossplane in dependency order. Sub-makes keep the phases sequential
# even when the top-level make command is invoked with parallel execution.
_crossplane-config:
	$(MAKE) crossplane-packages
	$(MAKE) crossplane-definitions
	$(MAKE) crossplane-compositions

# Install the provider/function packages only after Crossplane's package CRDs
# are established, then wait for the AWS ClusterProviderConfig API before use.
_crossplane-packages:
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
	@set -eu; rendered="$$(python3 platform/operations/render-platform.py --scope runtimes)"; printf '%s\n' "$$rendered" | kubectl apply -f -
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
	crds="$$(python3 -c 'import yaml; print(" ".join(yaml.safe_load(open("infrastructure/crossplane/packages/managed-resource-activation-policy.yaml"))["spec"]["activate"]))')"; \
	for crd in $$crds; do \
		kubectl wait --for=condition=Established "crd/$$crd" --timeout=300s; \
	done
	kubectl wait --for=condition=Established crd/clusterproviderconfigs.aws.m.upbound.io --timeout=300s
	kubectl apply -f infrastructure/crossplane/provider-configs/provider-config.yaml

# Install the direct namespaced v2 public APIs before their Compositions.
_crossplane-definitions:
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
_crossplane-compositions:
	@set -eu; rendered="$$(python3 platform/operations/render-platform.py --scope compositions)"; printf '%s\n' "$$rendered" | kubectl apply -f -
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
_argocd-up:
	@python3 platform/operations/render-platform.py --scope gitops >/dev/null
	@echo "$(GREEN)Installing ArgoCD...$(NC)"
	./platform/gitops/argocd/install/install.sh
	@echo "$(GREEN)Waiting for ArgoCD CRDs...$(NC)"
	kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=120s
	@echo "$(GREEN)Applying ArgoCD Projects and ApplicationSets...$(NC)"
	@set -eu; rendered="$$(python3 platform/operations/render-platform.py --scope gitops)"; printf '%s\n' "$$rendered" | kubectl apply -f -

.PHONY: platform-render
platform-render:
	python3 platform/operations/render-platform.py --scope bundle --output-dir platform/gitops/argocd/bootstrap

_platform-bootstrap-up:
	@python3 platform/operations/render-platform.py --scope gitops >/dev/null
	@test -s platform/gitops/argocd/bootstrap/manifest.yaml || { echo 'Render and merge the bootstrap bundle first.' >&2; exit 1; }
	@git ls-files --error-unmatch platform/gitops/argocd/bootstrap/manifest.yaml >/dev/null
	kubectl apply -f platform/gitops/argocd/projects/platform-bootstrap.yaml
	kubectl apply -f platform/gitops/argocd/platform-bootstrap.yaml

# Enforce policies that Kubernetes 1.36 supports natively. The installer waits
# for CEL type-checking before it enables the deny bindings.
_admission-up:
	@echo "$(GREEN)Installing native Kubernetes admission policies...$(NC)"
	./platform/security/admission/install.sh

# Kyverno is intentionally not part of the bootstrap until an approved release
# supports Kubernetes 1.36. Keep this target fail-closed for explicit callers.
kyverno-up:
	@echo "$(RED)Kyverno is disabled: the pinned policy engine is not approved for Kubernetes 1.36.$(NC)"
	@echo "Use 'make admission-up' for the supported native controls."
	@exit 1

# Configure Prometheus, Grafana, and Kubecost Monitoring & FinOps
_monitoring-up:
	@echo "$(GREEN)Installing Prometheus, Grafana, and Kubecost...$(NC)"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add kubecost https://kubecost.github.io/kubecost/ --force-update
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version $(PROMETHEUS_CHART_VERSION) -n monitoring -f platform/observability/prometheus/values.yaml --atomic --wait --timeout 15m
	kubectl apply -k platform/observability/grafana
	helm upgrade --install kubecost kubecost/kubecost --version $(KUBECOST_CHART_VERSION) -n monitoring -f platform/observability/kubecost/values.yaml --set-string global.clusterId=$(CLUSTER_NAME) --atomic --wait --timeout 15m

# Launch the lightweight local catalog. This is not the Backstage backend.
portal-up:
	@echo "$(GREEN)Launching local read-only IDP catalog on http://localhost:3000...$(NC)"
	node platform/developer-portal/local-catalog/server.js

# Stop GitOps before uninstalling its dependencies. Preserve namespaces, CRDs,
# claims and monitoring PVCs; Terraform owns the remaining core controllers.
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
	command -v helm >/dev/null; \
	for release_namespace in argocd:argocd kubecost:monitoring prometheus:monitoring reloader:reloader external-secrets:external-secrets kyverno:kyverno; do \
		release="$${release_namespace%%:*}"; namespace="$${release_namespace#*:}"; \
		KUBECONFIG="$$kubeconfig_snapshot" helm uninstall "$$release" --namespace "$$namespace" \
			--kube-context "$$context" --ignore-not-found --cascade foreground --wait --timeout 10m; \
	done; \
	KUBECONFIG="$$kubeconfig_snapshot" kubectl --context "$$context" delete -f platform/bootstrap/karpenter/node-pool.yaml --ignore-not-found --wait=true --timeout=10m; \
	KUBECONFIG="$$kubeconfig_snapshot" kubectl --context "$$context" delete -f platform/bootstrap/karpenter/node-class.yaml --ignore-not-found --wait=true --timeout=10m

# Bootstrap Kubernetes after all infrastructure plans have been reviewed/applied.
up:
	$(MAKE) cluster-up
	$(MAKE) monitoring-up

# Deliberately no one-command production destroy: each state needs its own plan.
down: confirm-destroy
	@echo 'Review retained-resource inventory and backups; use cluster-down, then a saved destroy plan for each Terraform layer.' >&2
	@exit 2

# Exercise every destructive guard path with local mock binaries only.
test-destroy-guard:
	./platform/operations/tests/verify-destroy-target.sh

# View status of EKS nodes and Karpenter NodePools
_status:
	kubectl cluster-info
	kubectl get nodes -o wide
	kubectl get nodepools

.PHONY: health-check
_health-check:
	kubectl get --raw=/readyz
	kubectl wait --for=condition=Ready nodes --all --timeout=60s
	kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=60s
	kubectl wait --for=condition=Available deployment --all -n argocd --timeout=60s

# Validate Terraform formatting and syntax
validate:
	terraform fmt -check -recursive infrastructure/terraform
	@set -eu; for root in infrastructure/terraform/stacks/bootstrap/state $(TF_DIR)/network $(TF_DIR)/eks $(TF_DIR)/controllers; do \
		terraform -chdir="$$root" init -backend=false -input=false -lockfile=readonly; \
		terraform -chdir="$$root" validate; \
	done

# Public Kubernetes entry points always use an isolated, verified EKS context.
GUARDED_TARGETS := cluster-up eso-up tenant-up reloader-up storage-up crossplane-config crossplane-packages crossplane-definitions crossplane-compositions argocd-up platform-bootstrap-up admission-up monitoring-up status health-check
.PHONY: $(GUARDED_TARGETS) $(addprefix _,$(GUARDED_TARGETS)) _require-verified-context
$(GUARDED_TARGETS):
	python3 platform/operations/in-cluster.py make _$@

$(addprefix _,$(GUARDED_TARGETS)): _require-verified-context
_require-verified-context:
	@test -n "$${IDP_VERIFIED_KUBECONFIG:-}" && test "$${KUBECONFIG:-}" = "$${IDP_VERIFIED_KUBECONFIG}" && test -f "$${KUBECONFIG}" || { echo 'Run the public Make target so EKS identity is verified first.' >&2; exit 1; }
