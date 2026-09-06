variable "service_repositories" {
  description = "Approved team/service paths; provision ECR before merging a scaffold PR"
  type        = set(string)
  validation {
    condition     = length(var.service_repositories) > 0 && alltrue([for name in var.service_repositories : length(name) <= 127 && can(regex("^[a-z][a-z0-9-]+/[a-z][a-z0-9-]+$", name)) && contains(var.tenant_namespaces, split("/", name)[0])])
    error_message = "Provide at least one approved tenant/service slug of at most 127 characters, for example identity-platform/login-app."
  }
}
resource "aws_ecr_repository" "service" {
  for_each             = var.service_repositories
  name                 = "idp-${replace(each.key, "/", "-")}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration { encryption_type = "AES256" }
  image_scanning_configuration { scan_on_push = true }
  tags = {
    Project     = "internal-developer-platform"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Team        = split("/", each.key)[0]
    Service     = split("/", each.key)[1]
  }
  lifecycle { prevent_destroy = true }
}
resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire only untagged layers after 30 days; preserve all release/rollback SHA tags"
      selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}
output "service_repository_urls" {
  value = { for service, repository in aws_ecr_repository.service : service => repository.repository_url }
}
