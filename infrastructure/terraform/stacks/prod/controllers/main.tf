terraform {
  required_version = ">= 1.11.0, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.62.0"
    }
  }
}
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "cluster_name" {
  type    = string
  default = "idp-prod"
}
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}
data "aws_ssm_parameter" "eks" { name = "/idp/${var.environment}/eks" }
locals { eks = jsondecode(nonsensitive(data.aws_ssm_parameter.eks.value)) }

provider "helm" {
  kubernetes {
    host                   = local.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(local.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", var.aws_region, "--cluster-name", var.cluster_name]
    }
  }
}
resource "terraform_data" "identity" {
  lifecycle {
    precondition {
      condition     = local.eks.schema_version == 1 && local.eks.environment == var.environment && local.eks.cluster_name == var.cluster_name
      error_message = "Controller configuration must match the production EKS contract."
    }
  }
}
module "controllers" {
  source                            = "../../../modules/controllers"
  cluster_name                      = var.cluster_name
  cluster_endpoint                  = local.eks.cluster_endpoint
  karpenter_queue_name              = local.eks.karpenter_queue_name
  karpenter_version                 = "1.14.1"
  crossplane_version                = "2.4.0"
  metrics_server_chart_version      = "3.13.1"
  aws_region                        = local.eks.aws_region
  vpc_id                            = local.eks.vpc_id
  load_balancer_controller_role_arn = local.eks.load_balancer_controller_role_arn
  depends_on                        = [terraform_data.identity, terraform_data.deployment_identity]
}
