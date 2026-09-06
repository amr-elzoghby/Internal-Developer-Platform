# Write-only secret input and ephemeral randomness never enter plan/state.
# Incrementing the version rotates the value; coordinate DB update and rollout.
ephemeral "random_password" "identity_platform_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "identity_platform_db_password" {
  name                    = "idp/identity-platform/db-password"
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "identity_platform_db_password" {
  secret_id                = aws_secretsmanager_secret.identity_platform_db_password.id
  secret_string_wo_version = var.database_password_version
  secret_string_wo = jsonencode({
    password = ephemeral.random_password.identity_platform_db_password.result
  })
}
