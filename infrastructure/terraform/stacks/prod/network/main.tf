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

module "network" {
  depends_on = [terraform_data.deployment_identity]
  source     = "../../../modules/network"

  environment  = var.environment
  name_prefix  = "idp-${var.environment}"
  aws_region   = var.aws_region
  cluster_name = var.cluster_name

  vpc_cidr = "10.0.0.0/16"

  subnet_layout = {
    a = {
      availability_zone = "${var.aws_region}a"
      public_cidr       = "10.0.1.0/24"
      private_cidr      = "10.0.32.0/20"
      data_cidr         = "10.0.20.0/24"
    }
    b = {
      availability_zone = "${var.aws_region}b"
      public_cidr       = "10.0.2.0/24"
      private_cidr      = "10.0.48.0/20"
      data_cidr         = "10.0.21.0/24"
    }
    c = {
      availability_zone = "${var.aws_region}c"
      public_cidr       = "10.0.3.0/24"
      private_cidr      = "10.0.64.0/20"
      data_cidr         = "10.0.22.0/24"
    }
  }

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



output "data_subnet_ids" { value = module.network.data_subnet_ids }
output "data_subnet_cidrs" { value = module.network.data_subnet_cidrs }
output "private_subnet_cidrs" { value = module.network.private_subnet_cidrs }
output "public_subnet_cidrs" { value = module.network.public_subnet_cidrs }
