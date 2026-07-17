# ─── Karpenter IAM (IRSA + SQS for Spot interruptions) ──────────────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = aws_eks_cluster.main.name

  enable_irsa                     = true
  irsa_oidc_provider_arn          = aws_iam_openid_connect_provider.eks.arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  create_node_iam_role = false
  node_iam_role_arn    = aws_iam_role.eks_nodes.arn
  create_access_entry  = false

  enable_spot_termination = true

  tags = {
    Environment = var.environment
  }
}

# ─── Karpenter Helm Release ──────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/templates/karpenter-values.yaml.tpl", {
      cluster_name     = aws_eks_cluster.main.name
      cluster_endpoint = aws_eks_cluster.main.endpoint
      queue_name       = module.karpenter.queue_name
      role_arn         = module.karpenter.iam_role_arn
    })
  ]

  depends_on = [
    aws_eks_node_group.stable,
    module.karpenter,
  ]
}
