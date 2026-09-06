variable "autoscaling_service_linked_role_arn" {
  description = "Existing account-global AutoScaling service-linked role ARN, when already provisioned"
  type        = string
  default     = null
}
resource "aws_iam_service_linked_role" "autoscaling" {
  count            = var.autoscaling_service_linked_role_arn == null ? 1 : 0
  aws_service_name = "autoscaling.amazonaws.com"
}
locals {
  autoscaling_role_arn = var.autoscaling_service_linked_role_arn != null ? var.autoscaling_service_linked_role_arn : aws_iam_service_linked_role.autoscaling[0].arn
}
data "aws_iam_policy_document" "node_encryption" {
  statement {
    sid       = "AccountKeyAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
  statement {
    sid       = "AutoScalingEncryptedVolumes"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_role_arn]
    }
  }
  statement {
    sid       = "AutoScalingVolumeGrants"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_role_arn]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}
resource "aws_kms_key" "nodes" {
  description             = "Stable EKS node root volumes"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.node_encryption.json
  lifecycle { prevent_destroy = true }
}
