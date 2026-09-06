terraform {
  required_version = ">= 1.11.0, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.62.0"
    }
  }
  # Bootstrap cannot use the bucket it is creating. Store this local state in
  # an access-controlled encrypted location; it is ignored by Git.
  backend "local" {}
}

variable "aws_account_id" {
  type        = string
  description = "Explicit destination account for the independent state bootstrap"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the intended 12-digit AWS account ID."
  }
}
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "environment" {
  type    = string
  default = "prod"
  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "State namespace must be prod, staging, or dev."
  }
}
variable "state_bucket_name" {
  type    = string
  default = "amr-tf-state-2026-851236938302-us-east-1-an"
}
variable "state_operator_role_names" {
  description = "Existing Terraform execution roles allowed to access these state keys"
  type        = set(string)
  default     = []
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = { Project = "internal-developer-platform", ManagedBy = "Terraform", Purpose = "terraform-state" }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform backend encryption and version recovery"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_alias" "state" {
  name          = "alias/idp-terraform-state"
  target_key_id = aws_kms_key.state.key_id
}
resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter { prefix = "" }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
    # State versions are deliberately never expired automatically.
  }
}
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "DenyWrongExplicitEncryptionAlgorithm"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }
  statement {
    sid       = "DenyWrongExplicitEncryptionKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn, aws_kms_alias.state.arn]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# Separate data and lock permissions: state objects cannot be deleted by the
# ordinary execution role, but .tflock objects must be deletable to unlock.
data "aws_iam_policy_document" "state_operator" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.environment}/*", "env:/*"]
    }
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [for layer in ["network", "eks", "controllers"] : "${aws_s3_bucket.state.arn}/${var.environment}/${layer}/terraform.tfstate"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for layer in ["network", "eks", "controllers"] : "${aws_s3_bucket.state.arn}/${var.environment}/${layer}/terraform.tfstate.tflock"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
}
resource "aws_iam_policy" "state_operator" {
  name   = "idp-terraform-state-access"
  policy = data.aws_iam_policy_document.state_operator.json
}
resource "aws_iam_role_policy_attachment" "state_operator" {
  for_each   = var.state_operator_role_names
  role       = each.value
  policy_arn = aws_iam_policy.state_operator.arn
}
output "bucket_name" { value = aws_s3_bucket.state.id }
output "kms_key_arn" { value = aws_kms_key.state.arn }
output "state_operator_policy_arn" { value = aws_iam_policy.state_operator.arn }
