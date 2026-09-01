# ─── Common ───────────────────────────────────────────────────────────────────
variable "environment" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Environment must be one of: prod, staging, dev."
  }
}

variable "name_prefix" {
  description = "Prefix for resource naming"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# ─── EKS Cluster ──────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"

  validation {
    condition     = contains(["1.34", "1.35", "1.36"], var.cluster_version)
    error_message = "Supported EKS versions: 1.34, 1.35, 1.36."
  }
}

variable "cluster_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "eks_addon_versions" {
  description = "Pinned EKS managed add-on versions compatible with the cluster version"
  type = object({
    vpc_cni            = string
    coredns            = string
    kube_proxy         = string
    ebs_csi_driver     = string
    pod_identity_agent = string
  })
}

variable "endpoint_private_access" {
  description = "Enable private API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable public API endpoint"
  type        = bool
  default     = true
}

variable "platform_access_entries" {
  description = "Explicit EKS access entries for platform operators and emergency access"
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
      for entry_name in keys(var.platform_access_entries) :
      can(regex("^[a-z0-9][a-z0-9-]{0,62}$", entry_name))
    ])
    error_message = "Platform access entry names must be lowercase slugs containing only letters, digits, and hyphens."
  }

  validation {
    condition = alltrue([
      for entry in values(var.platform_access_entries) :
      can(regex("^arn:aws:iam::[0-9]{12}:role/.+", entry.principal_arn)) &&
      !strcontains(entry.principal_arn, "REPLACE_ME")
    ])
    error_message = "Every platform principal must be a real IAM role ARN, not a placeholder, STS session ARN, or IAM user."
  }

  validation {
    condition = alltrue([
      for entry in values(var.platform_access_entries) :
      (length(entry.access_policies) > 0) != (length(entry.kubernetes_groups) > 0)
    ])
    error_message = "Each platform entry must use exactly one authorization path: EKS access policies or Kubernetes groups."
  }

  validation {
    condition = length(distinct([
      for entry in values(var.platform_access_entries) : entry.principal_arn
    ])) == length(var.platform_access_entries)
    error_message = "Each platform access entry must use a unique principal ARN."
  }

  validation {
    condition = alltrue(flatten([
      for entry in values(var.platform_access_entries) : [
        for policy_name in keys(entry.access_policies) :
        can(regex("^[a-z0-9][a-z0-9-]{0,62}$", policy_name))
      ]
    ]))
    error_message = "Access policy names must be lowercase slugs containing only letters, digits, and hyphens."
  }

  validation {
    condition = alltrue(flatten([
      for entry in values(var.platform_access_entries) : [
        for policy in values(entry.access_policies) : contains([
          "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
          "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
          "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy",
          "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy",
        ], policy.policy_arn)
      ]
    ]))
    error_message = "Only the approved AWS-managed EKS access policies may be associated with platform identities."
  }

  validation {
    condition = alltrue(flatten([
      for entry in values(var.platform_access_entries) : [
        for group in entry.kubernetes_groups : !startswith(group, "system:")
      ]
    ]))
    error_message = "Custom Kubernetes groups must not use the reserved system: prefix."
  }

  validation {
    condition = alltrue(flatten([
      for entry in values(var.platform_access_entries) : [
        for policy in values(entry.access_policies) :
        contains(["cluster", "namespace"], policy.scope_type) &&
        (policy.scope_type == "namespace" ? length(policy.namespaces) > 0 : length(policy.namespaces) == 0)
      ]
    ]))
    error_message = "Access policy scope must be cluster with no namespaces, or namespace with at least one namespace."
  }

  validation {
    condition = alltrue(flatten([
      for entry in values(var.platform_access_entries) : [
        for policy in values(entry.access_policies) : alltrue([
          for namespace in policy.namespaces :
          length(namespace) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", namespace))
        ])
      ]
    ]))
    error_message = "Namespace-scoped access policies must list explicit DNS-label namespace names; wildcards are not allowed."
  }
}

variable "tenant_namespaces" {
  description = "Approved host-cluster namespaces that form tenant boundaries"
  type        = set(string)

  validation {
    condition = length(var.tenant_namespaces) > 0 && alltrue([
      for namespace in var.tenant_namespaces :
      length(namespace) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", namespace))
    ])
    error_message = "Tenant namespaces must be non-empty Kubernetes DNS labels."
  }
}

variable "tenant_access_entries" {
  description = "EKS access entries that map tenant IAM roles to namespace-scoped Kubernetes RBAC groups"
  type = map(object({
    principal_arn = string
    tenant        = string
    access_level  = string
  }))

  validation {
    condition = alltrue([
      for entry_name in keys(var.tenant_access_entries) :
      can(regex("^[a-z0-9][a-z0-9-]{0,62}$", entry_name))
    ])
    error_message = "Tenant access entry names must be lowercase slugs containing only letters, digits, and hyphens."
  }

  validation {
    condition = alltrue([
      for entry in values(var.tenant_access_entries) :
      can(regex("^arn:aws:iam::[0-9]{12}:role/.+", entry.principal_arn)) &&
      !strcontains(entry.principal_arn, "REPLACE_ME")
    ])
    error_message = "Every tenant principal must be a real IAM role ARN, not a placeholder, STS session ARN, or IAM user."
  }

  validation {
    condition = length(distinct([
      for entry in values(var.tenant_access_entries) : entry.principal_arn
    ])) == length(var.tenant_access_entries)
    error_message = "Each tenant access entry must use a unique principal ARN."
  }

  validation {
    condition = alltrue([
      for entry in values(var.tenant_access_entries) :
      contains(["viewer", "operator"], entry.access_level)
    ])
    error_message = "Tenant access_level must be either viewer or operator."
  }
}

# ─── Stable Node Group (On-Demand) ───────────────────────────────────────────
variable "node_instance_type" {
  description = "EC2 instance type for stable worker nodes"
  type        = string
  default     = "t3.medium"

  validation {
    condition     = can(regex("^(t3|t3a|m5|m6i)\\.", var.node_instance_type))
    error_message = "Approved instance families: t3, t3a, m5, m6i."
  }
}

variable "node_desired_size" {
  description = "Desired number of stable nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1
    error_message = "Desired node count must be at least 1."
  }
}

variable "node_min_size" {
  description = "Minimum number of stable nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.node_min_size >= 1
    error_message = "Minimum node count must be at least 1."
  }
}

variable "node_max_size" {
  description = "Maximum number of stable nodes"
  type        = number
  default     = 4

  validation {
    condition     = var.node_max_size >= 1
    error_message = "Maximum node count must be at least 1."
  }
}

# ─── Karpenter ────────────────────────────────────────────────────────────────
variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.14.1"
}

variable "metrics_server_chart_version" {
  description = "Pinned Metrics Server Helm chart version"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.metrics_server_chart_version))
    error_message = "Metrics Server Helm chart version must use semantic version format, for example 3.13.1."
  }
}

# ─── Network (from remote state) ─────────────────────────────────────────────
variable "remote_state_bucket" {
  description = "S3 bucket for Terraform remote state"
  type        = string
}

variable "network_remote_state_key" {
  description = "S3 key for the network layer state"
  type        = string
  default     = "prod/network/terraform.tfstate"
}

# ─── Crossplane ───────────────────────────────────────────────────────────────
variable "crossplane_version" {
  description = "Crossplane Helm chart version"
  type        = string
  default     = "2.4.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.crossplane_version))
    error_message = "Crossplane Helm chart version must use semantic version format, for example 2.4.0."
  }
}
