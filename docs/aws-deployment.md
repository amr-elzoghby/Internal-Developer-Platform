# AWS deployment guide

This guide covers the optional cloud environment behind the [personal portfolio project](../README.md). End-to-end deployment has not been verified. The local catalog needs none of these steps.

Applying the configuration creates billable EKS, compute, NAT Gateway, endpoint and storage resources. Prepare the target account, access and budget before applying plans or running Kubernetes installation targets.

## Prerequisites and target identity

Use Terraform `>=1.11.0,<2.0`, AWS CLI, Helm, kubectl, Make, Node.js/npm and Python 3.13. The [quality workflow](../.github/workflows/quality.yaml) records the pinned validation dependencies. Version constraints and locks live with the Terraform roots, provider packages and Make targets.

The checked-in production identity is:

| Setting | Value |
|---|---|
| AWS account | `851236938302` |
| Region | `us-east-1` |
| EKS cluster | `idp-prod` |
| State bucket | `amr-tf-state-2026-851236938302-us-east-1-an` |

**Changing `AWS_PROFILE` alone is insufficient.** To use another account, update the identity consistently across Terraform roots/backends, `Makefile`, operations guards/rendering, GitHub Actions role and registry settings, and account-specific manifests. A fork also needs its repository URLs and GitHub OIDC trust updated. Re-run the identity guard tests for that target; do not bypass the guards.

Prepare an ignored `terraform.tfvars` from the [EKS example](../infrastructure/terraform/stacks/prod/eks/terraform.tfvars.example). Supply existing administrator, break-glass and tenant IAM roles, and an exact reviewed regional AL2023 AMI release. Placeholder ARNs and AMI values are not deployable inputs; an account root identity cannot be an EKS access-entry principal.

EKS uses a private API endpoint by default. The deployment runner needs network access to that endpoint before planning or installing controllers. Public endpoint access, if enabled, requires explicit approved CIDRs. An external application ingress additionally needs an owned hostname, DNS, certificate and load-balancer configuration.

## Terraform state and deployment order

```text
stacks/bootstrap/state       local state; provisions the remote backend
          ↓
stacks/prod/network          VPC, subnets, endpoints → SSM network contract
          ↓
stacks/prod/eks              cluster, IAM, add-ons → SSM controller contract
          ↓
stacks/prod/controllers      Karpenter, Crossplane, Metrics Server, AWS LBC
```

These paths are under [`infrastructure/terraform`](../infrastructure/terraform). The deployment roots use separate keys: `prod/network/terraform.tfstate`, `prod/eks/terraform.tfstate` and `prod/controllers/terraform.tfstate`. Consumers read explicit nonsecret SSM contracts instead of another stack's complete state.

The state-bootstrap root creates a private, versioned, KMS-encrypted bucket and state-operator permissions. It uses local state at `.idp/state-bootstrap/<environment>/terraform.tfstate`; preserve that file in restricted encrypted storage. Deployment roots use S3 lock files once the backend exists.

The gitignored `.idp/` directory also contains Terraform working data and saved plans. It is generated local data, but **it can contain real state**. Do not delete it as a general cleanup step. Keep state, plans, secrets and real `.tfvars` files out of Git. Clearing caches does not migrate or remove cloud resources.

For an existing installation, review any state migration before changing root boundaries. Do not recreate an existing state bucket or apply a new layout over controller releases already managed elsewhere.

Start by confirming the AWS identity and creating a plan:

```bash
aws sts get-caller-identity
make infra-plan STACK=state
```

This plans the bootstrap layer without provisioning it. Inspect the plan before applying it. `make infra-apply STACK=state` requires `APPROVE_PLAN_SHA256` to match that exact saved plan. The wrapper also verifies backend identity, account and Terraform source digest; source changes require a new plan.

Repeat the plan/review/apply sequence for `network`, `eks`, then `controllers`. Each real dependent plan requires the preceding layer's applied outputs. A mock plan cannot substitute for existing roles, SSM contracts or private endpoint access. `infra-up` aliases the saved-plan apply workflow; it does not supply approval.

## Kubernetes bootstrap and strict network policy

After the infrastructure layers are applied, `make up` runs cluster bootstrap and monitoring. It changes the live cluster. Public Kubernetes targets verify the AWS account and EKS identity using an isolated kubeconfig, and bootstrap phases remain sequential under `make -j`.

The cluster bootstrap order is:

```text
platform connectivity policies and strict CNI
→ Karpenter configuration → storage → External Secrets
→ tenants → Reloader → admission → Crossplane APIs → Argo CD
```

`make network-policy-up` first installs connectivity policies for `kube-system`, `crossplane-system`, `argocd`, `external-secrets`, `reloader` and `monitoring`. It then enables VPC CNI `NETWORK_POLICY_ENFORCING_MODE=strict` through the EKS add-on API. CoreDNS and controllers need their policies before strict startup. Argo CD retains its restricted ingress; its platform baseline supplies egress only. Tenant namespaces do not receive this broad platform baseline.

Terraform initially creates CNI in standard mode so CoreDNS can start before policies exist. Terraform continues to own the add-on version and IRSA role. The network-policy command owns `configuration_values` after creation, merges existing options and enables strict mode. Terraform ignores that field and uses `PRESERVE` on upgrades.

The operator needs `eks:DescribeAddon`, `eks:UpdateAddon`, `eks:DescribeUpdate` and Kubernetes permissions to apply these namespaces and policies. Tenant creation and GitOps activation check the live add-on configuration, node-agent enforcement, completed DaemonSet rollout and platform policies before applying workloads.

For an existing installation, first apply the reviewed EKS plan containing this CNI ownership arrangement, run `make network-policy-up`, and regenerate/review the bootstrap bundle. Preserve the platform policies during teardown while CNI remains strict. Verify startup/restart isolation and positive DNS/controller connectivity in a sandbox; rollout readiness alone does not establish network isolation.

After initial bootstrap:

1. Run `make platform-render` to generate nonsecret manifests in `platform/gitops/argocd/bootstrap` from verified Terraform outputs.
2. Review and merge the generated Git diff.
3. Run `make platform-bootstrap-up` to attach Argo CD to that merged bundle.

Sync waves wait for controller conditions and admission type-checking. Chart installations remain managed explicitly through Terraform or Make. Native admission updates compile candidate policies while previous Deny bindings remain active, then enable the candidates before retiring the previous revision.

`make status` reports cluster status and propagates errors. `make health-check` checks strict CNI, API readiness, nodes, the Karpenter NodeClass and Argo Deployments. Monitoring installation uses pinned charts, atomic rollback, readiness waits and timeouts.

## Tenant access and connectivity

The example tenants are `identity-platform`, `platform-engineering` and `data-platform`. The access path is `IAM role → EKS access entry → Kubernetes group → namespaced RoleBindings`. Viewer roles can inspect ordinary workloads and logs. Operator roles add limited pod deletion and scaling. Neither grants Secret access or RBAC mutation.

With a configured tenant SSO profile, an initial access check is:

```bash
aws sso login --profile identity-platform-viewer
aws eks update-kubeconfig --name idp-prod --region us-east-1 \
  --profile identity-platform-viewer --alias idp-prod-identity-platform-viewer
kubectl auth can-i get pods -n identity-platform       # expected: yes
kubectl auth can-i get secrets -n identity-platform    # expected: no
kubectl auth can-i get pods -n data-platform           # expected: no
```

Tenant NetworkPolicies allow same-namespace traffic, DNS and explicitly labelled PostgreSQL/Redis clients accessing isolated data subnet CIDRs rendered from reviewed outputs. General public HTTPS egress is denied. External APIs require a scoped platform NetworkPolicy change; NAT Gateways and endpoints do not override Pod policies. Database security groups allow the EKS node security group, with per-workload restrictions enforced by NetworkPolicies.

## Isolated sandbox

Use `python3 platform/operations/terraform-plan.py` with explicit `--environment` (`dev` or `staging`), `--account`, `--region`, `--cluster` (`idp-dev` or `idp-staging`), `--backend-bucket` and `--backend-region`, as well as the action and `--stack`. Its account and cluster must differ from production.

Bootstrap output access needs matching `IDP_ENVIRONMENT`, `IDP_AWS_ACCOUNT_ID`, `IDP_AWS_REGION`, `IDP_CLUSTER_NAME`, `IDP_BACKEND_BUCKET` and `IDP_BACKEND_REGION`. Identity/backend mismatches stop before apply. Checked-in GitOps applications and the bundle directory are production-only; sandbox runs use direct component targets and reviewed canary manifests. Bundle publication and application attachment reject sandbox outputs.

Validate positive and negative tenant access, network isolation, Crossplane reconciliation, application promotion/sync, monitoring, rotation and restoration before relying on the cloud environment.

## Resource lifecycle and teardown

Crossplane managed resources omit the `Delete` management policy. Claim removal therefore does not automatically delete cloud resources. The `gp3` StorageClass also retains EBS volumes after PVC deletion. Use the [Crossplane inventory tool](../infrastructure/crossplane/scripts/inventory.py), recovery copies and an explicit cleanup decision before decommissioning resources or removing their network.

RDS/Redis names, subnet groups and final snapshots use the reserved `idp-<environment>-crossplane-` prefix with a stable claim-UID hash. Inventory that namespace before first use and keep unrelated resources out of it: IAM ownership tags alone cannot distinguish newly created resources from existing untagged ones. Existing claims with older external names require a reviewed migration; Compositions reject automatic retargeting and tightened IAM does not grant access outside the prefix.

Infrastructure claims record an owner and ownership review date in AWS tags, use enforced Composition references and Manual revision updates. Promote revisions after a sandbox canary. Reloader watches tenant namespaces with scoped RBAC; when rotating a secret, keep former credentials valid until replacement Pods pass readiness and establish new database connections.

Destructive Make targets require the exact `CONFIRM_DESTROY=851236938302/us-east-1/idp-prod` value for the checked-in target. These identity constants cannot be overridden on the Make command line. Before any teardown, inspect the account, kube-context, saved plan, retained-resource inventory and backups.

The Terraform guard verifies AWS identity and reviewed inputs and forces the default workspace; providers and S3 backends also restrict the account. These checks do not establish what an existing state contains, so review each destroy plan. The Kubernetes guard snapshots the selected kube-context, verifies its endpoint and certificate against the active EKS cluster, checks delete permissions and pins all uninstall commands to that snapshot.

`make cluster-down` removes Argo CD first, then monitoring, Reloader, External Secrets and any legacy Kyverno release. It preserves namespaces, CRDs, claims and monitoring PVCs, then drains Karpenter NodePools before deleting the EC2NodeClass. A failed identity check or uninstall stops subsequent phases.

There is no one-command cloud destruction: `make down` and `make infra-down` direct the operator to separate saved destroy plans. EKS deletion protection and Terraform `prevent_destroy` rules also block teardown; changing those protections requires an explicit reviewed decommission decision before generating a usable destroy plan. Review and apply each layer in reverse order: controllers, EKS, then network, with the matching plan digest and confirmation. Protect the state backend until all dependent state and retained resources are accounted for. Removing EKS deletes the Kubernetes control plane; retained AWS resources may still exist and remain billable.
