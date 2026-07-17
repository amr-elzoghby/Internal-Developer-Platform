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

output "karpenter_irsa_role_arn" {
  description = "IRSA role ARN for Karpenter controller"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_queue_name" {
  description = "SQS queue name for Spot interruption handling"
  value       = module.karpenter.queue_name
}

output "kms_key_arn" {
  description = "KMS key ARN used for EKS secrets encryption"
  value       = aws_kms_key.eks.arn
}

output "crossplane_provider_role_arn" {
  description = "IRSA role ARN for Crossplane AWS provider"
  value       = aws_iam_role.crossplane_provider_aws.arn
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions OIDC integration"
  value       = aws_iam_role.github_actions.arn
}
