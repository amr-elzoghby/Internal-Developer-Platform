terraform {
  backend "s3" {
    bucket              = "amr-tf-state-2026-851236938302-us-east-1-an"
    key                 = "prod/network/terraform.tfstate"
    region              = "us-east-1"
    use_lockfile        = true
    encrypt             = true
    kms_key_id          = "arn:aws:kms:us-east-1:851236938302:alias/idp-terraform-state"
    allowed_account_ids = ["851236938302"]
  }
}
