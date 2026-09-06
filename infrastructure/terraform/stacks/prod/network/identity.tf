# These same roots can validate a future sandbox in a separate AWS account.
# Backend identity is independently verified by the saved-plan operations gate.
variable "aws_account_id" {
  description = "Explicit expected AWS account; a sandbox must use a different account"
  type        = string
  default     = "851236938302"
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Expected AWS account ID must contain exactly 12 digits."
  }
}
variable "environment" {
  type    = string
  default = "prod"
  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Environment must be prod, staging, or dev."
  }
}
resource "terraform_data" "deployment_identity" {
  lifecycle {
    precondition {
      condition     = terraform.workspace == "default" && var.cluster_name == "idp-${var.environment}"
      error_message = "Use workspace default and an explicit idp-<environment> cluster name."
    }
    precondition {
      condition     = var.environment == "prod" ? var.aws_account_id == "851236938302" : var.aws_account_id != "851236938302"
      error_message = "Production is bound to its reviewed account; sandbox environments require a different AWS account."
    }
  }
}
