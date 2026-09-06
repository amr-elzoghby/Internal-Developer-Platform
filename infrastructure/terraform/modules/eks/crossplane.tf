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
  permissions_boundary = {
    s3          = aws_iam_policy.crossplane_s3.arn
    rds         = aws_iam_policy.crossplane_rds.arn
    elasticache = aws_iam_policy.crossplane_elasticache.arn
    ec2         = aws_iam_policy.crossplane_ec2.arn
  }[each.key]
}

data "aws_iam_policy_document" "crossplane_s3" {
  statement {
    sid    = "DenyManagementOutsidePlatformBucketPrefix"
    effect = "Deny"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketTagging"
    ]
    not_resources = ["arn:aws:s3:::${var.name_prefix}-crossplane-*"]
  }

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
      "s3:PutBucketTagging", "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls", "s3:DeleteBucketOwnershipControls",
      "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy"
    ]
    resources = ["arn:aws:s3:::${var.name_prefix}-crossplane-*"]
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
    sid       = "ProtectOwnershipTagRemoval"
    effect    = "Deny"
    actions   = ["rds:RemoveTagsFromResource"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["ManagedBy", "Environment"]
    }
  }
  dynamic "statement" {
    for_each = { ManagedBy = "Crossplane-IDP", Environment = var.environment }
    content {
      sid       = "Protect${statement.key}TagValue"
      effect    = "Deny"
      actions   = ["rds:AddTagsToResource"]
      resources = ["*"]
      condition {
        test     = "Null"
        variable = "aws:RequestTag/${statement.key}"
        values   = ["false"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/${statement.key}"
        values   = [statement.value]
      }
    }
  }

  statement {
    sid       = "PassOnlyEnhancedMonitoringIdentity"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.rds_monitoring.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["monitoring.rds.amazonaws.com"]
    }
  }

  statement {
    sid       = "RequireOwnershipTagsOnCreate"
    effect    = "Deny"
    actions   = ["rds:CreateDBInstance", "rds:CreateDBSubnetGroup"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid    = "DenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "rds:AddTagsToResource", "rds:DeleteDBInstance", "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBInstance", "rds:ModifyDBSubnetGroup", "rds:RemoveTagsFromResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid       = "ManageRDSInstancesAndSubnetGroups"
    actions   = ["rds:AddTagsToResource", "rds:CreateDBInstance", "rds:CreateDBSubnetGroup", "rds:DeleteDBInstance", "rds:DeleteDBSubnetGroup", "rds:ListTagsForResource", "rds:ModifyDBInstance", "rds:ModifyDBSubnetGroup", "rds:RemoveTagsFromResource"]
    resources = ["arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }
  statement {
    sid       = "RegionalDiscoveryForReconciliation"
    actions   = ["rds:DescribeDBInstances", "rds:DescribeDBSubnetGroups", "rds:DescribeEngineDefaultParameters", "rds:DescribeEvents"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }


  statement {
    sid       = "EnvironmentRequireOwnershipTagsOnCreate"
    effect    = "Deny"
    actions   = ["rds:CreateDBInstance", "rds:CreateDBSubnetGroup"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid    = "EnvironmentDenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "rds:AddTagsToResource", "rds:DeleteDBInstance", "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBInstance", "rds:ModifyDBSubnetGroup", "rds:RemoveTagsFromResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }
}

resource "aws_iam_policy" "crossplane_rds" {
  name   = "${var.name_prefix}-crossplane-rds"
  policy = data.aws_iam_policy_document.crossplane_rds.json
}

data "aws_iam_policy_document" "crossplane_elasticache" {
  statement {
    sid       = "ProtectOwnershipTagRemoval"
    effect    = "Deny"
    actions   = ["elasticache:RemoveTagsFromResource"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["ManagedBy", "Environment"]
    }
  }
  dynamic "statement" {
    for_each = { ManagedBy = "Crossplane-IDP", Environment = var.environment }
    content {
      sid       = "Protect${statement.key}TagValue"
      effect    = "Deny"
      actions   = ["elasticache:AddTagsToResource"]
      resources = ["*"]
      condition {
        test     = "Null"
        variable = "aws:RequestTag/${statement.key}"
        values   = ["false"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/${statement.key}"
        values   = [statement.value]
      }
    }
  }

  statement {
    sid       = "RequireOwnershipTagsOnCreate"
    effect    = "Deny"
    actions   = ["elasticache:CreateCacheSubnetGroup", "elasticache:CreateReplicationGroup"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid    = "DenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "elasticache:AddTagsToResource", "elasticache:DeleteCacheSubnetGroup",
      "elasticache:DeleteReplicationGroup", "elasticache:ModifyCacheSubnetGroup",
      "elasticache:ModifyReplicationGroup", "elasticache:RemoveTagsFromResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid       = "ManageElastiCacheReplicationAndSubnetGroups"
    actions   = ["elasticache:AddTagsToResource", "elasticache:CreateCacheSubnetGroup", "elasticache:CreateReplicationGroup", "elasticache:DeleteCacheSubnetGroup", "elasticache:DeleteReplicationGroup", "elasticache:ListTagsForResource", "elasticache:ModifyCacheSubnetGroup", "elasticache:ModifyReplicationGroup", "elasticache:RemoveTagsFromResource"]
    resources = ["arn:aws:elasticache:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }
  statement {
    sid       = "RegionalDiscoveryForReconciliation"
    actions   = ["elasticache:DescribeCacheClusters", "elasticache:DescribeCacheSubnetGroups", "elasticache:DescribeEvents", "elasticache:DescribeReplicationGroups"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }


  statement {
    sid       = "EnvironmentRequireOwnershipTagsOnCreate"
    effect    = "Deny"
    actions   = ["elasticache:CreateCacheSubnetGroup", "elasticache:CreateReplicationGroup"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid    = "EnvironmentDenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "elasticache:AddTagsToResource", "elasticache:DeleteCacheSubnetGroup",
      "elasticache:DeleteReplicationGroup", "elasticache:ModifyCacheSubnetGroup",
      "elasticache:ModifyReplicationGroup", "elasticache:RemoveTagsFromResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }
}

resource "aws_iam_policy" "crossplane_elasticache" {
  name   = "${var.name_prefix}-crossplane-elasticache"
  policy = data.aws_iam_policy_document.crossplane_elasticache.json
}

data "aws_iam_policy_document" "crossplane_ec2" {
  statement {
    sid       = "ProtectOwnershipTagRemoval"
    effect    = "Deny"
    actions   = ["ec2:DeleteTags"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["ManagedBy", "Environment"]
    }
  }
  dynamic "statement" {
    for_each = { ManagedBy = "Crossplane-IDP", Environment = var.environment }
    content {
      sid       = "Protect${statement.key}TagValue"
      effect    = "Deny"
      actions   = ["ec2:CreateTags"]
      resources = ["*"]
      condition {
        test     = "Null"
        variable = "aws:RequestTag/${statement.key}"
        values   = ["false"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/${statement.key}"
        values   = [statement.value]
      }
    }
  }

  statement {
    sid       = "PassOnlyApprovedServerIdentity"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.crossplane_server.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
  statement {
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.crossplane_server.arn]
  }

  # RunInstances also authorizes existing security groups, which cannot have
  # request tags. Require tags only on the resource each action creates.
  dynamic "statement" {
    for_each = { RunInstances = "instance", CreateSecurityGroup = "security-group" }
    content {
      sid       = "RequireOwnershipTagsOn${statement.key}"
      effect    = "Deny"
      actions   = ["ec2:${statement.key}"]
      resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${statement.value}/*"]

      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/ManagedBy"
        values   = ["Crossplane-IDP"]
      }
    }
  }

  statement {
    sid       = "DenyTaggingResourcesNotOwnedByCrossplane"
    effect    = "Deny"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "ec2:CreateAction"
      values   = ["true"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid    = "DenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup", "ec2:DeleteTags", "ec2:ModifyInstanceAttribute",
      "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
      "ec2:StartInstances", "ec2:StopInstances", "ec2:TerminateInstances"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Crossplane-IDP"]
    }
  }

  statement {
    sid       = "ManageInstancesAndSecurityGroups"
    actions   = ["ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress", "ec2:CreateTags", "ec2:DeleteSecurityGroup", "ec2:DeleteTags", "ec2:ModifyInstanceAttribute", "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:StartInstances", "ec2:StopInstances", "ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }
  statement {
    sid       = "RegionalDiscoveryForReconciliation"
    actions   = ["ec2:DescribeImages", "ec2:DescribeInstanceAttribute", "ec2:DescribeInstanceCreditSpecifications", "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeSecurityGroupRules", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeTags", "ec2:DescribeVolumes", "ec2:DescribeVpcs"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }


  dynamic "statement" {
    for_each = { RunInstances = "instance", CreateSecurityGroup = "security-group" }
    content {
      sid       = "EnvironmentRequireOwnershipTagsOn${statement.key}"
      effect    = "Deny"
      actions   = ["ec2:${statement.key}"]
      resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${statement.value}/*"]

      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/Environment"
        values   = [var.environment]
      }
    }
  }

  statement {
    sid       = "EnvironmentDenyTaggingResourcesNotOwnedByCrossplane"
    effect    = "Deny"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "ec2:CreateAction"
      values   = ["true"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid    = "EnvironmentDenyChangesToResourcesNotOwnedByCrossplane"
    effect = "Deny"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup", "ec2:DeleteTags", "ec2:ModifyInstanceAttribute",
      "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
      "ec2:StartInstances", "ec2:StopInstances", "ec2:TerminateInstances"
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid     = "CreateSecurityGroupsOnlyInPlatformVPC"
    actions = ["ec2:CreateSecurityGroup"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc/${local.vpc_id}",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*"
    ]
  }
  statement {
    sid     = "LaunchApprovedImageInWorkerSubnets"
    actions = ["ec2:RunInstances"]
    resources = concat([
      "arn:aws:ec2:${var.aws_region}::image/${nonsensitive(data.aws_ssm_parameter.approved_server_ami.value)}",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:security-group/*"
    ], [for subnet in local.private_subnet_ids : "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/${subnet}"])
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
