resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = var.crossplane_version
  namespace  = "crossplane-system"

  create_namespace = true

  depends_on = [aws_eks_node_group.stable]
}

module "crossplane_provider_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name_prefix}-crossplane-provider-aws"

  oidc_providers = {
    ex = {
      provider_arn               = aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["crossplane-system:provider-aws-*"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "crossplane_s3" {
  role       = module.crossplane_provider_irsa.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_rds" {
  role       = module.crossplane_provider_irsa.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_elasticache" {
  role       = module.crossplane_provider_irsa.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_ec2_networking" {
  role       = module.crossplane_provider_irsa.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}
