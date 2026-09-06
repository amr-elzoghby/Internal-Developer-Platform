# ─── Karpenter IAM (Pod Identity + SQS for Spot interruptions) ──────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.2"

  cluster_name    = aws_eks_cluster.main.name
  region          = var.aws_region
  namespace       = "kube-system"
  service_account = "karpenter"

  create_node_iam_role                   = true
  node_iam_role_name                     = "${var.name_prefix}-karpenter-nodes-role"
  node_iam_role_use_name_prefix          = false
  node_iam_role_attach_cni_policy        = false
  node_iam_role_source_account_condition = true
  create_access_entry                    = true

  enable_spot_termination = true

  tags = {
    Environment = var.environment
  }
}

