terraform {
  required_version = ">= 1.11.0, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.62.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
  }
}
