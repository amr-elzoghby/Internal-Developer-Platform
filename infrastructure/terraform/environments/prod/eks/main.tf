provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "internal-developer-platform"
      Environment = "prod"
      ManagedBy   = "Terraform"
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
      command     = "aws"
    }
  }
}

module "eks" {
  source = "../../../modules/eks"

  environment = "prod"
  name_prefix = "idp-prod"
  aws_region  = var.aws_region

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  node_instance_type = "t3.medium"
  node_desired_size  = 2
  node_min_size      = 2
  node_max_size      = 4

  karpenter_version = "1.1.1"

  remote_state_bucket      = "amr-tf-state-2026-851236938302-us-east-1-an"
  network_remote_state_key = "prod/network/terraform.tfstate"
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
