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
