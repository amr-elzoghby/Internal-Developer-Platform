<div align="center">

<img src="docs/images/platform-architecture-hero.png" alt="Conceptual architecture of the Internal Developer Platform" width="100%"/>

# Internal Developer Platform

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.36-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Crossplane](https://img.shields.io/badge/Crossplane-2.4.0-5F43E9)](https://www.crossplane.io/)
[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.7-844FBA?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazonwebservices&logoColor=white)](https://aws.amazon.com/eks/)
[![Validation](https://img.shields.io/badge/status-statically_validated-yellow)](#validation-evidence)

An AWS EKS platform reference implementation built around reviewed Git changes, namespace-scoped tenancy, GitOps delivery, and namespaced Crossplane APIs.

</div>

> [!IMPORTANT]
> This repository has passed local and static validation, but the current revision has not been deployed end to end to a live AWS/EKS environment. “Configured” below means the implementation exists in Git; it does not mean a controller or cloud resource is currently running.

## What this repository contains

- Two Terraform roots: one for the VPC and one for EKS and its AWS integrations.
- Three native EKS tenant namespaces with EKS access entries, Kubernetes RBAC, quotas, limits, Pod Security Admission, and NetworkPolicies.
- Argo CD AppProjects and ApplicationSets scoped to each approved team.
- Four direct, namespaced Crossplane v2 APIs for S3, EC2, RDS PostgreSQL, and ElastiCache Redis.
- GitHub Actions that build changed monorepo services, scan them with Trivy, push immutable ECR tags, and open a manifest-update pull request.
- Backstage template definitions plus a lightweight, local, read-only catalog.
- Optional vCluster profiles for teams that genuinely need a separate Kubernetes API.

It does **not** currently provide a fully built Backstage application, a verified live cluster, automatic deployment for the standalone Node/Python template repositories, or a working external Ingress path.

## Current component status

| Area | Repository state | Live evidence |
|---|---|---|
| Terraform network | Implemented; `validate` passes | Not applied in this review |
| Terraform EKS | Implemented; `validate` passes with dependency deprecation warnings | Not applied in this review |
| Tenant RBAC and admission | Manifests implemented and parsed | No EKS API-server tests yet |
| Argo CD | Chart and boundaries configured | No sync test yet |
| Crossplane | Core, providers, XRDs, Compositions, and claims configured | No provider reconciliation test yet |
| GitHub Actions | Workflow implemented for `apps/<team>/<service>` | No workflow run verified for this revision |
| Local catalog | Read-only server and UI; local HTTP smoke passed | Local only |
| Backstage | Configuration, catalog entities, and templates only | Docker build is not self-contained |
| vCluster | Optional; Helm render passes for all three teams | No virtual cluster installed in this review |
| Monitoring | Values/dashboard files exist; separate Make target | No live Prometheus/Grafana/Kubecost evidence |
| Kyverno | Legacy policy files retained | Bootstrap intentionally disables it |

## Architecture

The generated image above is a high-level visual. This diagram is the source of truth for the relationships implemented in the repository:

```mermaid
flowchart LR
    DEV[Developer or platform engineer]
    GIT[(GitHub repository)]
    LOCAL[Local read-only catalog]
    TPL[Backstage templates]
    BOOT[Explicit Make bootstrap]
    CI[GitHub Actions]
    ECR[(Amazon ECR)]

    subgraph TF[Terraform]
        NETROOT[prod/network root]
        EKSROOT[prod/eks root]
        NETSTATE[(network remote state)]
    end

    subgraph AWS[AWS account]
        VPC[VPC, subnets and endpoints]

        subgraph HOST[Host EKS 1.36]
            ARGO[Argo CD]
            CP[Crossplane 2.4]
            ESO[External Secrets]
            POLICY[PSA and native admission]
            KARP[Karpenter and EKS add-ons]

            subgraph TENANTS[Native tenant namespaces]
                ID[identity-platform]
                PE[platform-engineering]
                DATA[data-platform]
            end

            VCL[Optional per-team vClusters]
        end

        CLOUD[S3, EC2, RDS and ElastiCache]
        SM[AWS Secrets Manager]
    end

    DEV -->|pull request| GIT
    LOCAL -. reads workspace metadata .-> GIT
    TPL -. intended scaffolder or claim PR .-> GIT
    DEV -->|authorized bootstrap command| BOOT
    GIT -->|changed app with Dockerfile| CI
    CI -->|immutable image| ECR
    CI -->|manifest update PR| GIT
    GIT -->|apps and claims| ARGO
    ARGO --> TENANTS
    ARGO -->|namespaced IDP claims| CP
    CP -->|IRSA, one role per provider family| CLOUD
    ESO -->|per-tenant IRSA| SM

    NETROOT --> VPC
    NETROOT --> NETSTATE
    NETSTATE --> EKSROOT
    EKSROOT -->|cluster, IAM, add-ons and core charts| KARP
    EKSROOT --> CP
    BOOT --> ESO
    BOOT --> POLICY
    BOOT --> ARGO
    BOOT --> CP
    BOOT --> TENANTS
    ECR --> TENANTS
    POLICY --> TENANTS
    KARP --> TENANTS
    TENANTS -. explicit opt-in .-> VCL
```

### Terraform dependency flow

```text
infrastructure/terraform/environments/prod/network
  └─ module.network
     ├─ VPC 10.0.0.0/16
     ├─ two public and two private subnets
     ├─ route tables and Internet Gateway
     ├─ node and endpoint Security Groups
     └─ S3, ECR, STS, EKS, EC2, SSM and Logs endpoints

network outputs
  └─ S3 remote state: prod/network/terraform.tfstate
     └─ read by prod/eks
        └─ module.eks
           ├─ EKS 1.36 and encrypted Kubernetes Secrets
           ├─ stable managed node group
           ├─ EKS managed add-ons and Metrics Server
           ├─ Karpenter and Crossplane Helm releases
           ├─ EKS access entries and tenant IRSA roles
           └─ GitHub Actions OIDC/ECR permissions
```

The roots deliberately use separate state keys:

- `prod/network/terraform.tfstate`
- `prod/eks/terraform.tfstate`

The backend bucket and DynamoDB lock table are assumed to exist; this repository does not bootstrap them.

## Tenant model

| Team | Native namespace | EKS groups | Argo CD project | Optional vCluster host namespace |
|---|---|---|---|---|
| Identity Platform | `identity-platform` | `idp:tenant:identity-platform:viewer/operator` | `identity-platform` | `vcluster-identity-platform` |
| Platform Engineering | `platform-engineering` | `idp:tenant:platform-engineering:viewer/operator` | `platform-engineering` | `vcluster-platform-engineering` |
| Data Platform | `data-platform` | `idp:tenant:data-platform:viewer/operator` | `data-platform` | `vcluster-data-platform` |

Native namespaces are the default isolation boundary. A viewer can inspect ordinary workload resources and logs inside its own namespace. An operator adds limited pod deletion and scale operations. Neither role is granted Secret access or RBAC mutation.

Each namespace receives:

- `ResourceQuota` and `LimitRange`.
- a restricted workload ServiceAccount with token automount disabled by default.
- a per-tenant External Secrets IRSA identity.
- Pod Security labels: baseline enforced; restricted audited and warned.
- native admission rules for explicit non-`latest` images, CPU/memory requests and limits, and a team label matching the namespace.
- a default tenant NetworkPolicy that permits same-namespace traffic, DNS, and HTTPS egress.

The current HTTPS egress and database Security Group rules are transitional and broader than the final target; see [Known gaps](#known-gaps).

## GitOps and application delivery

Argo CD watches:

- `apps/identity-platform/*`
- `apps/platform-engineering/*`
- `apps/data-platform/*`
- `infrastructure/crossplane/claims/*`

Team AppProjects can deploy only to their own namespace and only approved namespaced workload kinds. The default project is closed. The infrastructure project accepts only the four `idp.io` claim kinds and External Secrets resources in approved tenant namespaces.

For a service already inside `apps/<team>/<service>` with a `Dockerfile`:

```text
merge app change to main
→ GitHub Actions detects the service
→ assume AWS role with GitHub OIDC
→ build or reuse the commit-SHA image
→ fail on CRITICAL Trivy findings
→ push to an immutable ECR repository
→ open a dedicated manifest-update pull request
→ review and merge
→ Argo CD reconciles the manifest
```

The workflow does not build the current `login-app` example because that directory contains only a deployment manifest. Its old ECR repository name is intentionally retained until the published artifact is verified and copied by digest.

## Crossplane infrastructure APIs

Crossplane uses direct namespaced v2 XRDs. A claim and its generated managed resources stay in the requesting namespace.

| API | AWS resources generated | Current safety defaults |
|---|---|---|
| `ObjectBucket` | S3 Bucket | generated platform-prefixed name and management tags; explicit encryption/versioning/public-access resources are not implemented yet |
| `ServerInstance` | EC2 Instance, Security Group, rule | private subnet, approved sizes, and AMI ID format validation; IMDSv2 and root-volume encryption are not declared yet |
| `PostgresSQLInstance` | RDS Instance, subnet group, Security Group, rule | private, encrypted gp3, 7-day backups, deletion protection |
| `RedisInstance` | ElastiCache Replication Group, subnet group, Security Group, rule | private subnet placement and approved sizes; further hardening required |

The package layer is intentionally limited:

- Crossplane Core `2.4.0`
- Upbound AWS providers `2.7.1` for S3, EC2, RDS, and ElastiCache
- Crossplane Function Python `0.5.0`
- one `ClusterProviderConfig`
- four dedicated IRSA roles
- one ManagedResourceActivationPolicy activating exactly eight managed resource kinds

Managed resources omit the `Delete` management policy. Removing a Git claim therefore does not automatically delete the cloud resource. This protects stateful resources from accidental Git pruning, but requires an explicit orphan cleanup and deletion runbook.

The approved database template writes a PostgreSQL claim and ExternalSecret into the monorepo claims path through a pull request. Redis, S3, and EC2 have APIs but no reviewed Backstage request template yet.

## Developer experience

### Local catalog

`make portal-up` launches `platform/backstage-portal/server.js` on `127.0.0.1:3000`.

It can:

- scan local `catalog-info.yaml` files;
- show detected infrastructure YAML files;
- display the four implemented API contracts;
- present a local team view selector.

It cannot authenticate users, enforce RBAC, write files, run Git commands, provision infrastructure, or report live Kubernetes/Argo/Trivy/SonarQube metrics. The team selector is presentation-only.

### Backstage assets

`platform/backstage` contains catalog/configuration material, not a self-contained Backstage application. Its Dockerfile expects a Backstage monorepo with `package.json`, `yarn.lock`, `packages`, and `plugins`, which are not present here.

The Node.js and Python templates currently publish standalone repositories. They are useful scaffolds, but those repositories are not discovered by the current monorepo ApplicationSets. This integration gap is tracked in the hardening plan.

## Security controls represented in code

- EKS Secrets encryption with a rotating customer-managed KMS key.
- EKS control-plane logging for API, audit, authenticator, controller manager, and scheduler.
- IMDSv2 required in the stable node launch template.
- IRSA trust restricted to exact provider or tenant ServiceAccounts.
- separate Crossplane IAM roles for each AWS service family.
- an explicit deny preventing the S3 provider from accessing the Terraform state bucket.
- ownership-tag guardrails around managed RDS, ElastiCache, and EC2 resources.
- namespace-scoped tenant RBAC with no Secret or RBAC write permissions.
- Pod Security Admission and fail-closed native ValidatingAdmissionPolicies.
- Argo CD destination and resource allowlists.
- GitHub Actions OIDC, empty workflow-level permissions, immutable ECR tags, and a CRITICAL Trivy gate.
- confirmation guard before destructive Make targets.

These are implementation controls, not audit evidence. IAM behavior, admission behavior, and isolation still need live positive and negative tests.

## Version pins

| Component | Version or constraint |
|---|---|
| Kubernetes / EKS | `1.36` |
| Terraform | network `>=1.5.0`; EKS `>=1.5.7` |
| AWS provider | network `~>5.0`; EKS `>=6.52,<7.0` |
| Karpenter | `1.14.1` |
| Crossplane | `2.4.0` |
| Upbound AWS providers | `2.7.1` |
| Function Python | `0.5.0` |
| Argo CD Helm chart | `10.1.4` |
| vCluster Helm chart | `0.36.1` |
| Metrics Server chart | `3.13.1` |
| VPC CNI | `v1.22.4-eksbuild.3` |
| CoreDNS | `v1.14.3-eksbuild.14` |
| kube-proxy | `v1.36.0-eksbuild.17` |
| EBS CSI | `v1.65.0-eksbuild.1` |
| EKS Pod Identity Agent | `v1.3.10-eksbuild.3` |

External Secrets, Prometheus, and Kubecost chart versions are not pinned in the Makefile yet.

## Repository map

```text
.
├── .github/
│   ├── CODEOWNERS
│   └── workflows/service-ci.yaml
├── apps/
│   └── identity-platform/login-app/deployment.yaml
├── golden-paths/
│   ├── infra-database/
│   ├── nodejs-service/
│   └── python-fastapi/
├── infrastructure/
│   ├── terraform/
│   │   ├── environments/prod/{network,eks}/
│   │   └── modules/{network,eks}/
│   └── crossplane/
│       ├── providers/
│       ├── definitions/
│       ├── compositions/
│       ├── claims/identity-platform/
│       └── scripts/
├── platform/
│   ├── argocd/
│   ├── backstage/
│   ├── backstage-portal/
│   ├── karpenter/
│   ├── monitoring/
│   ├── security/{admission,kyverno}/
│   └── vcluster/{base,host-namespaces,teams}/
├── tenants/
│   ├── base/
│   ├── namespaces/
│   ├── rbac/
│   └── templates/
├── folder-restructure-tomorrow.md
├── platform-hardening-plan.md
├── Makefile
└── README.md
```

## Safe local validation

Prerequisites:

- Terraform `>=1.5.7`
- AWS CLI, Helm, kubectl, Make
- Python 3 and `envsubst`
- Node.js for the local catalog

Commands that do not intentionally apply infrastructure:

```bash
# May download providers, but uses no remote backend.
make validate

# Inspect the command graph without executing it.
make -n cluster-up
make -n tenant-up
make -n vcluster-up TEAM=identity-platform

# Run the read-only local catalog. PROJECTS_DIR must contain service
# repositories with catalog-info.yaml at their top level.
PROJECTS_DIR=/path/to/service-workspace make portal-up
```

Before any AWS plan:

1. Confirm the intended AWS account and `us-east-1` region.
2. Create or deliberately replace the backend bucket and lock-table configuration.
3. Copy `infrastructure/terraform/environments/prod/eks/terraform.tfvars.example` to an ignored `terraform.tfvars`.
4. Replace every `REPLACE_ME` IAM role ARN with a real role in the cluster account.
5. Review the network plan first, then the EKS plan.

```bash
terraform -chdir=infrastructure/terraform/environments/prod/network init
terraform -chdir=infrastructure/terraform/environments/prod/network plan

terraform -chdir=infrastructure/terraform/environments/prod/eks init
terraform -chdir=infrastructure/terraform/environments/prod/eks plan
```

Do not use `make up` as a first validation command: `infra-up` currently invokes `terraform apply -auto-approve`.

## Validation evidence

The current revision was checked with:

- Terraform formatting and validation for both roots.
- YAML and JSON parsing across repository manifests.
- Helm template rendering for vCluster `0.36.1` for all three teams.
- rendered Golden Path checks for YAML, JavaScript, and Python.
- JavaScript syntax checks for the local catalog.
- local HTTP smoke tests for catalog, health, and claim-spec endpoints.
- negative local tests confirming removed login/write endpoints return `404` and path traversal does not expose files.
- Make dry-runs for tenant and optional-vCluster paths.
- reference searches for retired team names and portal capabilities.

The EKS Terraform validation reports deprecation warnings from the downloaded `terraform-aws-modules/iam` dependency. They do not fail validation, but the module should be upgraded in a reviewed change.

## Known gaps

The full risk register and ordered remediation plan live in [platform-hardening-plan.md](platform-hardening-plan.md). The highest-priority gaps are:

1. No end-to-end deployment or live isolation evidence.
2. Stable EKS nodes currently target public subnets.
3. The EKS public endpoint has no CIDR allowlist in this module.
4. NGINX Ingress resources exist without an installed NGINX controller.
5. standalone service templates are not connected to the monorepo Argo CD contract.
6. Crossplane provider schemas, EC2 namespaced rendering, and connection-secret keys need live canaries.
7. S3 and EC2 Compositions do not yet declare the required production data and instance hardening controls.
8. tenant HTTPS egress and RDS/Redis VPC-wide ingress are broader than the target design.
9. Redis lacks production encryption, authentication, high availability, and backup settings.
10. External Secrets and monitoring chart versions are unpinned.
11. Backstage is configuration-only, not a runnable production portal.

The planned repository reorganization is documented separately in [folder-restructure-tomorrow.md](folder-restructure-tomorrow.md). It has not been executed.

## Destructive operations

`make down`, `make infra-down`, and `make cluster-down` require the exact `CONFIRM_DESTROY=idp-prod` value. `cluster-down` does not explicitly delete tenant namespaces, and `vcluster-down` retains Helm history and PVCs. The full `make down` path still destroys the EKS infrastructure, so it is destructive to everything hosted on that cluster.

Even with that guard, always inspect the active AWS account, kube-context, Terraform plan, backups, and rollback path before running a destructive command.

---

Maintained by [Amr Elzoghby](https://github.com/amr-elzoghby).
