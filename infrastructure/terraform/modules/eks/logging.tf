data "aws_iam_policy_document" "control_plane_logging_key" {
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
    sid       = "CloudWatchEncryptedLogs"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster"]
    }
  }
}
resource "aws_kms_key" "control_plane_logs" {
  description             = "Encryption for control_plane logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.control_plane_logging_key.json
  lifecycle { prevent_destroy = true }
}
resource "aws_cloudwatch_log_group" "control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.control_plane_logs.arn
  skip_destroy      = true
}
