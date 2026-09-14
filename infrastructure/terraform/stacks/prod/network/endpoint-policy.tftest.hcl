# Render policy documents with the real provider, without contacting AWS.
# The plan creates no resources and the only AWS lookup is overridden below.
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

variables {
  environment  = "dev"
  name_prefix  = "idp-dev"
  cluster_name = "idp-dev"
  subnet_layout = {
    a = { availability_zone = "us-east-1a", public_cidr = "10.0.1.0/24", private_cidr = "10.0.32.0/20", data_cidr = "10.0.20.0/24" }
    b = { availability_zone = "us-east-1b", public_cidr = "10.0.2.0/24", private_cidr = "10.0.48.0/20", data_cidr = "10.0.21.0/24" }
  }
}

run "sts_endpoint_policy" {
  command = plan
  module { source = "../../../modules/network" }

  # The evaluator below intentionally supports only these policy constructs.
  # Fail if a policy change needs richer IAM semantics rather than guessing.
  assert {
    condition = alltrue([for statement in jsondecode(aws_vpc_endpoint.sts[0].policy).Statement :
      statement.Effect == "Allow" && statement.Principal == "*" && statement.Resource == "*" &&
      length(setsubtract(keys(statement), ["Sid", "Effect", "Principal", "Action", "Resource", "Condition"])) == 0 &&
      length(setsubtract(keys(try(statement.Condition, {})), ["StringEquals"])) == 0 &&
      alltrue([for action in try(tolist(statement.Action), [statement.Action]) :
        action == "*" || (!strcontains(action, "*") && !strcontains(action, "?"))
      ])
    ])
    error_message = "Endpoint policy uses IAM constructs outside this regression evaluator's supported subset."
  }

  assert {
    condition = alltrue([for request in [
      { action = "sts:AssumeRoleWithWebIdentity", context = { "aws:ResourceAccount" = "123456789012" }, allowed = true },
      { action = "sts:AssumeRoleWithWebIdentity", context = { "aws:ResourceAccount" = "999999999999" }, allowed = false },
      { action = "sts:AssumeRoleWithWebIdentity", context = {}, allowed = false },
      { action = "sts:GetCallerIdentity", context = { "aws:PrincipalAccount" = "123456789012" }, allowed = true },
      { action = "sts:GetCallerIdentity", context = { "aws:PrincipalAccount" = "999999999999" }, allowed = false },
      { action = "sts:GetCallerIdentity", context = { "aws:ResourceAccount" = "123456789012" }, allowed = false },
      { action = "sts:AssumeRoleWithSAML", context = { "aws:ResourceAccount" = "123456789012" }, allowed = false },
      ] : request.allowed == anytrue([for statement in jsondecode(aws_vpc_endpoint.sts[0].policy).Statement :
        anytrue([for action in try(tolist(statement.Action), [statement.Action]) :
          action == "*" || lower(action) == lower(request.action)
        ]) &&
        alltrue([for key, expected in try(statement.Condition.StringEquals, {}) :
          contains(keys(request.context), key) &&
          contains(try(tolist(expected), [expected]), lookup(request.context, key, ""))
        ])
      ])
    ])
    error_message = "STS must allow account-scoped IRSA federation, reject other or missing target accounts, and retain the signed-caller account boundary."
  }
}
