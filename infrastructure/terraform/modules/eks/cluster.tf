# ─── Remote State (network) ───────────────────────────────────────────────────
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = var.network_remote_state_key
    region = var.aws_region
  }
}

locals {
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids
}

# ─── EKS Cluster ──────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  enabled_cluster_log_types = var.cluster_log_types

  vpc_config {
    subnet_ids              = concat(local.private_subnet_ids, local.public_subnet_ids)
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

# ─── KMS Key (encrypts K8s Secrets at rest) ──────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.name_prefix}-eks-secrets-key"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name_prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# ─── Launch Template for Stable Node Group (Enforces IMDSv2) ──────────────────
resource "aws_launch_template" "stable" {
  name_prefix   = "${var.name_prefix}-stable-lt-"
  description   = "Launch template for stable node group forcing IMDSv2"
  instance_type = var.node_instance_type

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_protocol_ipv6          = "disabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-stable-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Stable Node Group (On-Demand — platform controllers) ────────────────────
resource "aws_eks_node_group" "stable" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-stable"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = local.public_subnet_ids

  launch_template {
    id      = aws_launch_template.stable.id
    version = aws_launch_template.stable.latest_version
  }

  labels = {
    role = "stable"
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}
