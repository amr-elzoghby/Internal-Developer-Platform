resource "aws_ssm_parameter" "contract" {
  name = "/idp/${var.environment}/eks"
  type = "String"
  value = jsonencode({
    schema_version                    = 1
    environment                       = var.environment
    aws_region                        = var.aws_region
    vpc_id                            = local.vpc_id
    cluster_name                      = aws_eks_cluster.main.name
    cluster_endpoint                  = aws_eks_cluster.main.endpoint
    cluster_ca_certificate            = aws_eks_cluster.main.certificate_authority[0].data
    karpenter_queue_name              = module.karpenter.queue_name
    administration_role_arn           = var.platform_access_entries["platform-admin"].principal_arn
    load_balancer_controller_role_arn = aws_iam_role.load_balancer_controller.arn
  })
  depends_on = [aws_eks_access_policy_association.platform, aws_eks_node_group.stable, aws_eks_addon.pod_identity_agent, aws_iam_service_linked_role.platform, data.aws_iam_role.existing_service_linked, aws_iam_role_policy_attachment.load_balancer_controller]
  lifecycle { prevent_destroy = true }
}
