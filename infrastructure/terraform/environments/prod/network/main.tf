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

module "network" {
  source = "../../../modules/network"

  environment  = "prod"
  name_prefix  = "idp-prod"
  aws_region   = var.aws_region
  cluster_name = var.cluster_name

  vpc_cidr = "10.0.0.0/16"

  availability_zones   = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_vpc_endpoints = true
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "eks_nodes_security_group_id" {
  value = module.network.eks_nodes_security_group_id
}
