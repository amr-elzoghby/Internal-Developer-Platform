mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  environment  = "dev"
  name_prefix  = "idp-dev"
  cluster_name = "idp-dev"
  aws_region   = "us-east-1"
  vpc_cidr     = "10.0.0.0/16"
  subnet_layout = {
    a = { availability_zone = "us-east-1a", public_cidr = "10.0.1.0/24", private_cidr = "10.0.32.0/20", data_cidr = "10.0.20.0/24" }
    b = { availability_zone = "us-east-1b", public_cidr = "10.0.2.0/24", private_cidr = "10.0.48.0/20", data_cidr = "10.0.21.0/24" }
  }
}

run "private_network_contract" {
  command = plan
  module { source = "../../../modules/network" }
  assert {
    condition     = alltrue([for subnet in values(aws_subnet.public) : !subnet.map_public_ip_on_launch]) && alltrue([for subnet in values(aws_subnet.private) : !subnet.map_public_ip_on_launch])
    error_message = "No worker or load-balancer subnet may automatically allocate public instance addresses."
  }
  assert {
    condition     = alltrue([for subnet in values(aws_subnet.private) : subnet.tags["karpenter.sh/discovery"] == "idp-dev"]) && alltrue([for subnet in values(aws_subnet.public) : !contains(keys(subnet.tags), "karpenter.sh/discovery")])
    error_message = "Karpenter discovery must select only private worker subnets."
  }
  assert {
    condition     = length(aws_nat_gateway.private_egress) == 2 && length(aws_subnet.data) == 2
    error_message = "Each AZ needs independent NAT egress and an isolated data subnet."
  }
}

run "reject_overlapping_subnets" {
  command = plan
  module { source = "../../../modules/network" }
  variables {
    subnet_layout = {
      a = { availability_zone = "us-east-1a", public_cidr = "10.0.1.0/24", private_cidr = "10.0.32.0/20", data_cidr = "10.0.1.0/24" }
      b = { availability_zone = "us-east-1b", public_cidr = "10.0.2.0/24", private_cidr = "10.0.48.0/20", data_cidr = "10.0.21.0/24" }
    }
  }
  expect_failures = [aws_vpc.main]
}

run "reject_subnets_outside_vpc" {
  command = plan
  module { source = "../../../modules/network" }
  variables {
    subnet_layout = {
      a = { availability_zone = "us-east-1a", public_cidr = "10.0.1.0/24", private_cidr = "10.0.32.0/20", data_cidr = "10.9.20.0/24" }
      b = { availability_zone = "us-east-1b", public_cidr = "10.0.2.0/24", private_cidr = "10.0.48.0/20", data_cidr = "10.0.21.0/24" }
    }
  }
  expect_failures = [aws_vpc.main]
}

run "reject_duplicate_availability_zone" {
  command = plan
  module { source = "../../../modules/network" }
  variables {
    subnet_layout = {
      a = { availability_zone = "us-east-1a", public_cidr = "10.0.1.0/24", private_cidr = "10.0.32.0/20", data_cidr = "10.0.20.0/24" }
      b = { availability_zone = "us-east-1a", public_cidr = "10.0.2.0/24", private_cidr = "10.0.48.0/20", data_cidr = "10.0.21.0/24" }
    }
  }
  expect_failures = [var.subnet_layout]
}
