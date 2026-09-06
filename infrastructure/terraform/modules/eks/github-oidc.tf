# ─── Data Source for AWS Caller Identity ─────────────────────────────────────
data "aws_caller_identity" "current" {}

# ─── IAM Role for GitHub Actions (Uses account-level GitHub OIDC Provider) ───
resource "aws_iam_role" "github_actions" {
  name = "${var.name_prefix}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.github_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:amr-elzoghby/Internal-Developer-Platform:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.name_prefix}-github-actions-role"
  }
}

# ─── IAM Policy for ECR Registry Access ────────────────────────────────────────
resource "aws_iam_policy" "github_actions_ecr" {
  name        = "${var.name_prefix}-github-actions-ecr-policy"
  description = "Permissions for GitHub Actions to authenticate and push to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:GetLifecyclePolicy",
          "ecr:ListTagsForResource",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = [for repository in values(aws_ecr_repository.service) : repository.arn]
      }
    ]
  })
}

# ─── Policy Attachment ────────────────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_ecr.arn
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN, or null to provision it once in a fresh account"
  type        = string
  default     = null
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
locals {
  github_oidc_provider_arn = var.github_oidc_provider_arn != null ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}
resource "aws_iam_role" "github_actions_read" {
  name = "${var.name_prefix}-github-actions-read-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:amr-elzoghby/Internal-Developer-Platform:pull_request",
            "repo:amr-elzoghby/Internal-Developer-Platform:ref:refs/heads/main"
          ]
        }
      }
    }]
  })
}
resource "aws_iam_role_policy" "github_actions_read" {
  role = aws_iam_role.github_actions_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:GetLifecyclePolicy", "ecr:ListTagsForResource"]
        Resource = [for repository in values(aws_ecr_repository.service) : repository.arn]
      }
    ]
  })
}
output "github_actions_read_role_arn" { value = aws_iam_role.github_actions_read.arn }
