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

# ─── Karpenter CRDs ─────────────────────────────────────────────────────────
resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.karpenter_version
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  wait            = true

  depends_on = [aws_eks_node_group.stable]
}

# ─── Karpenter Helm Release ──────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  namespace  = "kube-system"
  skip_crds  = true

  atomic          = true
  cleanup_on_fail = true
  wait            = true

  values = [
    templatefile("${path.module}/templates/karpenter-values.yaml.tpl", {
      cluster_name     = aws_eks_cluster.main.name
      cluster_endpoint = aws_eks_cluster.main.endpoint
      queue_name       = module.karpenter.queue_name
    })
  ]

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_eks_node_group.stable,
    helm_release.karpenter_crd,
    module.karpenter,
  ]
}
