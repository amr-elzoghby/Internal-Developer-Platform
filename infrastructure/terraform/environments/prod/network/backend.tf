terraform {
  backend "s3" {
    bucket = "amr-tf-state-2026-851236938302-us-east-1-an"
    key    = "prod/network/terraform.tfstate"
    region = "us-east-1"
  }
}
