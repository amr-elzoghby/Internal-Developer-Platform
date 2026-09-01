# ─── Per-Tenant External Secrets IRSA ────────────────────────────────────────
data "aws_partition" "current" {}

data "aws_iam_policy_document" "tenant_external_secrets_assume_role" {
  for_each = var.tenant_namespaces

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
      values   = ["system:serviceaccount:${each.key}:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tenant_external_secrets" {
  for_each = var.tenant_namespaces

  name               = "${var.name_prefix}-${each.key}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.tenant_external_secrets_assume_role[each.key].json

  tags = {
    Tenant  = each.key
    Service = "external-secrets"
  }
}

data "aws_iam_policy_document" "tenant_external_secrets" {
  for_each = var.tenant_namespaces

  statement {
    sid = "ReadTenantSecrets"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:idp/${each.key}/*",
    ]
  }
}

resource "aws_iam_policy" "tenant_external_secrets" {
  for_each = var.tenant_namespaces

  name   = "${var.name_prefix}-${each.key}-external-secrets"
  policy = data.aws_iam_policy_document.tenant_external_secrets[each.key].json
}

resource "aws_iam_role_policy_attachment" "tenant_external_secrets" {
  for_each = var.tenant_namespaces

  role       = aws_iam_role.tenant_external_secrets[each.key].name
  policy_arn = aws_iam_policy.tenant_external_secrets[each.key].arn
}
