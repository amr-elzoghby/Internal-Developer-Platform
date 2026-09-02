resource "random_password" "identity_platform_db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "identity_platform_db_password" {
  name                    = "idp/identity-platform/db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "identity_platform_db_password" {
  secret_id = aws_secretsmanager_secret.identity_platform_db_password.id
  secret_string = jsonencode({
    password = random_password.identity_platform_db_password.result
  })
}
