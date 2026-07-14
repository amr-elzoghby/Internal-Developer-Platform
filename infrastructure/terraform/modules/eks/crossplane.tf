resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = var.crossplane_version
  namespace  = "crossplane-system"

  create_namespace = true

  depends_on = [aws_eks_node_group.stable]
}

data "aws_iam_policy_document" "crossplane_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }

    condition {
      test     = "StringLike"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:crossplane-system:provider-aws-*",
        "system:serviceaccount:crossplane-system:upbound-provider-family-aws-*"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crossplane_provider_aws" {
  name               = "${var.name_prefix}-crossplane-provider-aws"
  assume_role_policy = data.aws_iam_policy_document.crossplane_assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "crossplane_s3" {
  role       = aws_iam_role.crossplane_provider_aws.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_rds" {
  role       = aws_iam_role.crossplane_provider_aws.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_elasticache" {
  role       = aws_iam_role.crossplane_provider_aws.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess"
}

resource "aws_iam_role_policy_attachment" "crossplane_ec2_networking" {
  role       = aws_iam_role.crossplane_provider_aws.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}
