# ─── Explicit EKS Access Entries ─────────────────────────────────────────────
locals {
  platform_access_policy_associations = merge([
    for entry_name, entry in var.platform_access_entries : {
      for policy_name, policy in entry.access_policies :
      "${entry_name}/${policy_name}" => {
        entry_name = entry_name
        policy_arn = policy.policy_arn
        scope_type = policy.scope_type
        namespaces = policy.namespaces
      }
    }
  ]...)
}

resource "aws_eks_access_entry" "platform" {
  for_each = var.platform_access_entries

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = length(each.value.kubernetes_groups) > 0 ? each.value.kubernetes_groups : null
  type              = "STANDARD"

  tags = {
    Name       = "${var.name_prefix}-${each.key}-access"
    AccessRole = each.key
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = split(":", each.value.principal_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "Platform access principals must belong to the AWS account that owns this EKS cluster."
    }
  }
}

resource "aws_eks_access_policy_association" "platform" {
  for_each = local.platform_access_policy_associations

  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = each.value.policy_arn
  principal_arn = aws_eks_access_entry.platform[each.value.entry_name].principal_arn

  access_scope {
    type       = each.value.scope_type
    namespaces = each.value.scope_type == "namespace" ? each.value.namespaces : null
  }
}

# Tenant principals deliberately receive Kubernetes groups only. Namespace
# permissions are granted later by RoleBindings, not by cluster-wide EKS
# access policies.
resource "aws_eks_access_entry" "tenant" {
  for_each = var.tenant_access_entries

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = ["idp:tenant:${each.value.tenant}:${each.value.access_level}"]
  type              = "STANDARD"

  tags = {
    Name        = "${var.name_prefix}-${each.key}-access"
    Tenant      = each.value.tenant
    AccessLevel = each.value.access_level
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = contains(var.tenant_namespaces, each.value.tenant)
      error_message = "Tenant access entry '${each.key}' references an unknown tenant namespace."
    }

    precondition {
      condition     = split(":", each.value.principal_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "Tenant access principals must belong to the AWS account that owns this EKS cluster."
    }

    precondition {
      condition = !contains([
        for entry in values(var.platform_access_entries) : entry.principal_arn
      ], each.value.principal_arn)
      error_message = "A principal cannot be both a platform identity and a tenant identity."
    }
  }
}
