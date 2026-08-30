resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = var.crossplane_version
  namespace  = "crossplane-system"

  create_namespace = true
  depends_on       = [aws_eks_node_group.stable]
}

locals {
  crossplane_providers = {
    s3          = "provider-aws-s3"
    rds         = "provider-aws-rds"
    elasticache = "provider-aws-elasticache"
    ec2         = "provider-aws-ec2"
  }
}

data "aws_iam_policy_document" "crossplane_assume_role" {
  for_each = local.crossplane_providers

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:crossplane-system:${each.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crossplane_provider" {
  for_each = local.crossplane_providers

  name               = "${var.name_prefix}-crossplane-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.crossplane_assume_role[each.key].json
}

data "aws_iam_policy_document" "crossplane_s3" {
  statement {
    sid = "ManageCrossplaneBuckets"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl", "s3:GetBucketCORS", "s3:GetBucketLocation",
      "s3:GetBucketLogging", "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls", "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock", "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging", "s3:GetBucketVersioning", "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration", "s3:ListBucket", "s3:ListBucketVersions",
      "s3:PutBucketTagging"
    ]
    resources = ["arn:aws:s3:::*"]
  }

  statement {
    sid       = "ListBucketsForReconciliation"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid     = "DenyTerraformStateAccess"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${var.remote_state_bucket}",
      "arn:aws:s3:::${var.remote_state_bucket}/*"
    ]
  }
}

resource "aws_iam_policy" "crossplane_s3" {
  name   = "${var.name_prefix}-crossplane-s3"
  policy = data.aws_iam_policy_document.crossplane_s3.json
}

data "aws_iam_policy_document" "crossplane_rds" {
  statement {
    sid = "ManageRDSInstancesAndSubnetGroups"
    actions = [
      "rds:AddTagsToResource", "rds:CreateDBInstance", "rds:CreateDBSubnetGroup",
      "rds:DeleteDBInstance", "rds:DeleteDBSubnetGroup", "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups", "rds:DescribeEngineDefaultParameters",
      "rds:DescribeEvents", "rds:ListTagsForResource", "rds:ModifyDBInstance",
      "rds:ModifyDBSubnetGroup", "rds:RemoveTagsFromResource"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "crossplane_rds" {
  name   = "${var.name_prefix}-crossplane-rds"
  policy = data.aws_iam_policy_document.crossplane_rds.json
}

data "aws_iam_policy_document" "crossplane_elasticache" {
  statement {
    sid = "ManageElastiCacheReplicationAndSubnetGroups"
    actions = [
      "elasticache:AddTagsToResource", "elasticache:CreateCacheSubnetGroup",
      "elasticache:CreateReplicationGroup", "elasticache:DeleteCacheSubnetGroup",
      "elasticache:DeleteReplicationGroup", "elasticache:DescribeCacheClusters",
      "elasticache:DescribeCacheSubnetGroups", "elasticache:DescribeEvents",
      "elasticache:DescribeReplicationGroups", "elasticache:ListTagsForResource",
      "elasticache:ModifyCacheSubnetGroup", "elasticache:ModifyReplicationGroup",
      "elasticache:RemoveTagsFromResource"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "crossplane_elasticache" {
  name   = "${var.name_prefix}-crossplane-elasticache"
  policy = data.aws_iam_policy_document.crossplane_elasticache.json
}

data "aws_iam_policy_document" "crossplane_ec2" {
  statement {
    sid = "ManageInstancesAndSecurityGroups"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateSecurityGroup", "ec2:CreateTags", "ec2:DeleteSecurityGroup",
      "ec2:DeleteTags", "ec2:DescribeImages", "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceCreditSpecifications", "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus", "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeTags",
      "ec2:DescribeVolumes", "ec2:DescribeVpcs", "ec2:ModifyInstanceAttribute",
      "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
      "ec2:RunInstances", "ec2:StartInstances", "ec2:StopInstances",
      "ec2:TerminateInstances"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "crossplane_ec2" {
  name   = "${var.name_prefix}-crossplane-ec2"
  policy = data.aws_iam_policy_document.crossplane_ec2.json
}

resource "aws_iam_role_policy_attachment" "crossplane_provider" {
  for_each = local.crossplane_providers

  role = aws_iam_role.crossplane_provider[each.key].name
  policy_arn = {
    s3          = aws_iam_policy.crossplane_s3.arn
    rds         = aws_iam_policy.crossplane_rds.arn
    elasticache = aws_iam_policy.crossplane_elasticache.arn
    ec2         = aws_iam_policy.crossplane_ec2.arn
  }[each.key]
}
