provider "aws" {
  region              = var.aws_region
  allowed_account_ids = ["851236938302"]

  default_tags {
    tags = {
      Project     = "internal-developer-platform"
      Environment = "prod"
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  tenant_namespaces = toset(["identity-platform", "platform-engineering", "data-platform"])
}

module "eks" {
  source = "../../../modules/eks"

  environment = "prod"
  name_prefix = "idp-prod"
  aws_region  = var.aws_region

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  endpoint_public_access = length(var.public_access_cidrs) > 0
  public_access_cidrs    = var.public_access_cidrs

  node_instance_type = "t3.medium"
  node_desired_size  = 2
  node_min_size      = 2
  node_max_size      = 4

  platform_access_entries = var.platform_access_entries
  tenant_access_entries   = var.tenant_access_entries
  tenant_namespaces       = local.tenant_namespaces

  eks_addon_versions = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    coredns            = "v1.14.3-eksbuild.14"
    kube_proxy         = "v1.36.0-eksbuild.17"
    ebs_csi_driver     = "v1.65.0-eksbuild.1"
    pod_identity_agent = "v1.3.10-eksbuild.3"
  }

  remote_state_bucket = "amr-tf-state-2026-851236938302-us-east-1-an"
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "crossplane_provider_role_arns" {
  value = module.eks.crossplane_provider_role_arns
}

output "github_actions_role_arn" {
  value = module.eks.github_actions_role_arn
}

output "tenant_external_secrets_role_arns" {
  value = module.eks.tenant_external_secrets_role_arns
}
