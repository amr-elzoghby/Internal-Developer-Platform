terraform {
  backend "s3" {
    bucket = "idp-terraform-state-Amr.s.ELzoghby"
    key    = "prod/network/terraform.tfstate"
    region = "us-east-1"
  }
}
