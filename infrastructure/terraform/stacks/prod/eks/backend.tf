terraform {
  backend "s3" {
    bucket              = "amr-tf-state-2026-851236938302-us-east-1-an"
    key                 = "prod/eks/terraform.tfstate"
    region              = "us-east-1"
    dynamodb_table      = "terraform-state-lock"
    encrypt             = true
    allowed_account_ids = ["851236938302"]
  }
}
