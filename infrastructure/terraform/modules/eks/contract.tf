resource "aws_ssm_parameter" "contract" {
  name = "/idp/${var.environment}/eks"
  type = "String"
  value = jsonencode({
    schema_version          = 1
    environment             = var.environment
    cluster_name            = aws_eks_cluster.main.name
    cluster_endpoint        = aws_eks_cluster.main.endpoint
    cluster_ca_certificate  = aws_eks_cluster.main.certificate_authority[0].data
    karpenter_queue_name    = module.karpenter.queue_name
    administration_role_arn = var.platform_access_entries["platform-admin"].principal_arn
  })
  depends_on = [aws_eks_access_policy_association.platform, aws_eks_node_group.stable, aws_eks_addon.pod_identity_agent]
  lifecycle { prevent_destroy = true }
}
