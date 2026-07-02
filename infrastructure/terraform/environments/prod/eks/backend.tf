terraform {
  backend "s3" {
    bucket = "idp-terraform-state-Amr.s.ELzoghby"
    key    = "prod/eks/terraform.tfstate"
    region = "us-east-1"
  }
}
