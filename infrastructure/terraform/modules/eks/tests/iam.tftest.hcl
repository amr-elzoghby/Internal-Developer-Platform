# Render the real policy documents without contacting AWS or creating resources.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "offline-test"
  secret_key                  = "offline-test"
  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = data.aws_ssm_parameter.network
  values = {
    value = <<-JSON
      {
        "schema_version": 1,
        "environment": "dev",
        "cluster_name": "idp-dev",
        "vpc_id": "vpc-0123456789abcdef0",
        "private_subnet_ids": ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"],
        "public_subnet_ids": ["subnet-2123456789abcdef0", "subnet-3123456789abcdef0"]
      }
    JSON
  }
}

override_data {
  target = data.aws_ssm_parameter.approved_server_ami
  values = { value = "ami-0123456789abcdef0" }
}

override_resource {
  target = aws_iam_role.crossplane_server
  values = { arn = "arn:aws:iam::123456789012:role/idp-dev-crossplane-server" }
}

override_resource {
  target = aws_iam_instance_profile.crossplane_server
  values = { arn = "arn:aws:iam::123456789012:instance-profile/idp-dev-crossplane-server" }
}

override_resource {
  target = aws_iam_role.rds_monitoring
  values = { arn = "arn:aws:iam::123456789012:role/idp-dev-rds-enhanced-monitoring" }
}

override_module {
  target = module.karpenter
  outputs = {
    queue_name         = "idp-dev-karpenter"
    iam_role_arn       = "arn:aws:iam::123456789012:role/idp-dev-karpenter"
    node_iam_role_arn  = "arn:aws:iam::123456789012:role/idp-dev-karpenter-node"
    node_iam_role_name = "idp-dev-karpenter-node"
  }
}

variables {
  environment              = "dev"
  name_prefix              = "idp-dev"
  cluster_name             = "idp-dev"
  remote_state_bucket      = "idp-dev-state"
  node_ami_release_version = "1.36.0-20260901"
  service_repositories     = ["identity-platform/login-app"]
  tenant_namespaces        = ["identity-platform"]
  tenant_access_entries    = {}
  platform_access_entries = {
    platform-admin = {
      principal_arn     = "arn:aws:iam::123456789012:role/platform-admin"
      kubernetes_groups = ["idp:platform-admins"]
    }
  }
  eks_addon_versions = {
    vpc_cni            = "v1.22.4-eksbuild.3"
    coredns            = "v1.13.2-eksbuild.1"
    kube_proxy         = "v1.36.0-eksbuild.1"
    ebs_csi_driver     = "v1.62.0-eksbuild.1"
    pod_identity_agent = "v1.3.10-eksbuild.3"
  }
}

# Only these overridden identities enter the test state. Real AWS resources
# are never applied; the following run merely plans the remaining module.
run "prepare_mock_identities" {
  command = apply
  plan_options {
    target = [aws_iam_role.crossplane_server, aws_iam_instance_profile.crossplane_server, aws_iam_role.rds_monitoring]
  }
}

run "crossplane_policy_contract" {
  command = plan

  assert {
    condition = alltrue([for policy in [
      data.aws_iam_policy_document.crossplane_s3.json,
      data.aws_iam_policy_document.crossplane_ec2.json,
      data.aws_iam_policy_document.crossplane_rds.json,
      data.aws_iam_policy_document.crossplane_elasticache.json,
    ] : length(jsonencode(jsondecode(policy))) <= 6144])
    error_message = "Crossplane managed IAM policies must fit the AWS 6144-character limit."
  }

  assert {
    condition = alltrue(flatten([for statement in jsondecode(data.aws_iam_policy_document.crossplane_ec2.json).Statement : [
      for resource in try(tolist(statement.Resource), [statement.Resource]) : endswith(resource, ":instance/*")
      ] if statement.Effect == "Deny" && contains(try(tolist(statement.Action), [statement.Action]), "ec2:RunInstances") && (
      can(statement.Condition.StringNotEquals["aws:RequestTag/ManagedBy"]) || can(statement.Condition.StringNotEquals["aws:RequestTag/Environment"])
    )]))
    error_message = "Launch tag requirements may target only new instances, not existing security groups."
  }

  assert {
    condition = length([for statement in jsondecode(data.aws_iam_policy_document.crossplane_ec2.json).Statement : statement
      if statement.Effect == "Deny" && contains(try(tolist(statement.Action), [statement.Action]), "ec2:RunInstances") && (
        can(statement.Condition.StringNotEquals["aws:RequestTag/ManagedBy"]) || can(statement.Condition.StringNotEquals["aws:RequestTag/Environment"])
    )]) == 2
    error_message = "Launching an instance must still require both ownership and environment tags."
  }
}
