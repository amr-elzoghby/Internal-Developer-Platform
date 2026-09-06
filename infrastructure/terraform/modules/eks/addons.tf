resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.eks_addon_versions.ebs_csi_driver
  service_account_role_arn    = aws_iam_role.addon["ebs-csi"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    controller = {
      replicaCount = 2
      nodeSelector = { role = "stable" }
      tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    }
  })
  depends_on = [aws_eks_node_group.stable]
}

# ─── CoreDNS Addon ───────────────────────────────────────────────────────────
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.eks_addon_versions.coredns
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    replicaCount = 3
    nodeSelector = { role = "stable" }
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" },
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" }
    ]
    podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
    topologySpreadConstraints = [{
      maxSkew       = 1, topologyKey = "topology.kubernetes.io/zone", whenUnsatisfiable = "ScheduleAnyway"
      labelSelector = { matchLabels = { "k8s-app" = "kube-dns" } }
    }]
  })
  depends_on = [aws_eks_node_group.stable]
}

# ─── VPC CNI Addon (IRSA — enables pod-level security groups) ────────────────
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.eks_addon_versions.vpc_cni
  service_account_role_arn    = aws_iam_role.addon["vpc-cni"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_iam_role_policy_attachment.addon]

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

}

# ─── kube-proxy Addon ────────────────────────────────────────────────────────
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.eks_addon_versions.kube_proxy
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.stable]
}

# ─── EKS Pod Identity Agent ──────────────────────────────────────────────────
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = var.eks_addon_versions.pod_identity_agent
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.stable]
}

