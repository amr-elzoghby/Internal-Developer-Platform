output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "API endpoint of the EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64 encoded CA certificate"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider (used for IRSA)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_role_arn" {
  description = "IAM role ARN of the worker nodes"
  value       = aws_iam_role.eks_nodes.arn
}

output "karpenter_controller_role_arn" {
  description = "Pod Identity IAM role ARN for the Karpenter controller"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_arn" {
  description = "Dedicated IAM role ARN for Karpenter-provisioned nodes"
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Dedicated IAM role name for Karpenter-provisioned nodes"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  description = "SQS queue name for Spot interruption handling"
  value       = module.karpenter.queue_name
}

output "kms_key_arn" {
  description = "KMS key ARN used for EKS secrets encryption"
  value       = aws_kms_key.eks.arn
}

output "crossplane_provider_role_arns" {
  description = "IRSA role ARNs keyed by Crossplane AWS provider name"
  value = {
    for provider, role in aws_iam_role.crossplane_provider : provider => role.arn
  }
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions OIDC integration"
  value       = aws_iam_role.github_actions.arn
}

output "tenant_external_secrets_role_arns" {
  description = "IRSA role ARNs used by each tenant SecretStore"
  value = {
    for tenant, role in aws_iam_role.tenant_external_secrets : tenant => role.arn
  }
}

output "node_security_group_id" {
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
output "vpc_id" { value = local.vpc_id }
