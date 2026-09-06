# These account-global prerequisites are bootstrapped by Terraform, so runtime
# controllers can retain boundaries that forbid IAM role creation.
variable "existing_service_linked_roles" {
  description = "AWS services whose standard service-linked role already exists in this account"
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for service in var.existing_service_linked_roles : contains(["rds.amazonaws.com", "elasticache.amazonaws.com", "spot.amazonaws.com"], service)])
    error_message = "Existing services must be rds.amazonaws.com, elasticache.amazonaws.com, or spot.amazonaws.com."
  }
}
locals {
  service_linked_role_names = {
    "rds.amazonaws.com"         = "AWSServiceRoleForRDS"
    "elasticache.amazonaws.com" = "AWSServiceRoleForElastiCache"
    "spot.amazonaws.com"        = "AWSServiceRoleForEC2Spot"
  }
}
resource "aws_iam_service_linked_role" "platform" {
  for_each         = { for service, name in local.service_linked_role_names : service => name if !contains(var.existing_service_linked_roles, service) }
  aws_service_name = each.key
  lifecycle { prevent_destroy = true }
}
data "aws_iam_role" "existing_service_linked" {
  for_each = var.existing_service_linked_roles
  name     = local.service_linked_role_names[each.key]
  lifecycle {
    postcondition {
      condition     = self.path == "/aws-service-role/${each.key}/"
      error_message = "The existing role must be the standard AWS service-linked role, not an ordinary role with a similar name."
    }
  }
}
