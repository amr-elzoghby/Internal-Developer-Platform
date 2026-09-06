variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "idp-prod"
}

variable "platform_access_entries" {
  description = "Explicit production EKS access for platform administrators and break-glass operators"
  type = map(object({
    principal_arn     = string
    kubernetes_groups = optional(set(string), [])
    access_policies = optional(map(object({
      policy_arn = string
      scope_type = optional(string, "cluster")
      namespaces = optional(set(string), [])
    })), {})
  }))

  validation {
    condition = alltrue([for name, entry in var.platform_access_entries :
      contains(["platform-admin", "break-glass"], name) == contains(entry.kubernetes_groups, "idp:platform-admins")
    ])
    error_message = "Only platform-admin and break-glass must map idp:platform-admins for audited admission-policy administration."
  }

  validation {
    condition = alltrue([
      contains(keys(var.platform_access_entries), "platform-admin"),
      contains(keys(var.platform_access_entries), "break-glass"),
    ])
    error_message = "Production requires both platform-admin and break-glass access entries."
  }

  validation {
    condition = alltrue([
      for entry_name in ["platform-admin", "break-glass"] : contains([
        for policy in values(var.platform_access_entries[entry_name].access_policies) : policy.policy_arn
        if policy.scope_type == "cluster"
      ], "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy")
      if contains(keys(var.platform_access_entries), entry_name)
    ])
    error_message = "platform-admin and break-glass must both receive AmazonEKSClusterAdminPolicy."
  }

  validation {
    condition = alltrue([
      for entry_name, entry in var.platform_access_entries :
      contains(["platform-admin", "break-glass"], entry_name) || !contains([
        for policy in values(entry.access_policies) : policy.policy_arn
      ], "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy")
    ])
    error_message = "Only platform-admin and break-glass may receive AmazonEKSClusterAdminPolicy."
  }
}

variable "tenant_access_entries" {
  description = "Production tenant IAM roles mapped to host-cluster Kubernetes groups"
  type = map(object({
    principal_arn = string
    tenant        = string
    access_level  = string
  }))

  validation {
    condition = alltrue([
      for entry in values(var.tenant_access_entries) :
      contains(["identity-platform", "platform-engineering", "data-platform"], entry.tenant)
    ])
    error_message = "Every tenant access entry must target an approved production tenant."
  }

  validation {
    condition = alltrue(flatten([
      for tenant in ["identity-platform", "platform-engineering", "data-platform"] : [
        for access_level in ["viewer", "operator"] : contains([
          for entry in values(var.tenant_access_entries) : "${entry.tenant}/${entry.access_level}"
        ], "${tenant}/${access_level}")
      ]
    ]))
    error_message = "Production requires both a viewer and an operator access entry for every tenant."
  }
}

variable "public_access_cidrs" {
  description = "Trusted administrator egress IPv4 CIDRs; empty uses a private-only API and requires a VPC-connected runner/VPN"
  type        = set(string)
  default     = []
}

variable "database_password_version" {
  description = "Explicit rotation sequence; increment only with a reviewed database/consumer rotation procedure"
  type        = number
  default     = 1
  validation {
    condition     = var.database_password_version >= 1 && floor(var.database_password_version) == var.database_password_version
    error_message = "Secret version must be a positive integer."
  }
}

variable "node_ami_release_version" {
  description = "Exact approved regional EKS 1.36 AL2023 optimized AMI release; no floating latest value"
  type        = string
}

variable "service_repositories" {
  description = "Preprovisioned team/service ECR inventory; add a service before merging its scaffold"
  type        = set(string)
  default     = ["identity-platform/login-app"]
}

variable "state_bucket_name" {
  description = "Actual backend bucket, also explicitly denied to Crossplane"
  type        = string
  default     = "amr-tf-state-2026-851236938302-us-east-1-an"
}
variable "autoscaling_service_linked_role_arn" {
  description = "Existing AWS AutoScaling service-linked role ARN, or null for a fresh account"
  type        = string
  default     = null
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN, or null for a fresh account"
  type        = string
  default     = null
}

variable "existing_service_linked_roles" {
  description = "Account-global RDS, ElastiCache, or Spot service principals already bootstrapped"
  type        = set(string)
  default     = []
}
