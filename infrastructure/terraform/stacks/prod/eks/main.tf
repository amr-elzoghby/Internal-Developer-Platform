provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "internal-developer-platform"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  tenant_namespaces = toset(["identity-platform", "platform-engineering", "data-platform"])
}

module "eks" {
  depends_on = [terraform_data.deployment_identity]
  source     = "../../../modules/eks"

  environment = var.environment
  name_prefix = "idp-${var.environment}"
  aws_region  = var.aws_region

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  endpoint_public_access = length(var.public_access_cidrs) > 0
  public_access_cidrs    = var.public_access_cidrs

  node_instance_type                  = "m6i.large"
  node_desired_size                   = 3
  node_min_size                       = 3
  node_max_size                       = 6
  node_ami_release_version            = var.node_ami_release_version
  autoscaling_service_linked_role_arn = var.autoscaling_service_linked_role_arn

  platform_access_entries       = var.platform_access_entries
  tenant_access_entries         = var.tenant_access_entries
  tenant_namespaces             = local.tenant_namespaces
  service_repositories          = var.service_repositories
  github_oidc_provider_arn      = var.github_oidc_provider_arn
  existing_service_linked_roles = var.existing_service_linked_roles

  eks_addon_versions = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    coredns            = "v1.14.3-eksbuild.14"
    kube_proxy         = "v1.36.0-eksbuild.17"
    ebs_csi_driver     = "v1.65.0-eksbuild.1"
    pod_identity_agent = "v1.3.10-eksbuild.3"
  }

  remote_state_bucket = var.state_bucket_name
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

output "node_security_group_id" { value = module.eks.node_security_group_id }
output "vpc_id" { value = module.eks.vpc_id }
output "platform_context" {
  value = {
    aws_account_id = var.aws_account_id
    aws_region     = var.aws_region
    cluster_name   = var.cluster_name
    environment    = var.environment
  }
}

output "service_repository_urls" { value = module.eks.service_repository_urls }

output "approved_server_ami_id" { value = module.eks.approved_server_ami_id }
output "ec2_instance_profile_name" { value = module.eks.ec2_instance_profile_name }

output "rds_monitoring_role_arn" { value = module.eks.rds_monitoring_role_arn }

output "load_balancer_controller_role_arn" { value = module.eks.load_balancer_controller_role_arn }

output "github_actions_read_role_arn" { value = module.eks.github_actions_read_role_arn }

output "karpenter_node_role_name" { value = module.eks.karpenter_node_role_name }
output "karpenter_node_role_arn" { value = module.eks.karpenter_node_role_arn }
output "karpenter_controller_role_arn" { value = module.eks.karpenter_controller_role_arn }
output "karpenter_queue_name" { value = module.eks.karpenter_queue_name }
