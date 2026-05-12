output "db_password" {
  value     = random_password.db_password.result
  sensitive = true
}

output "clickhouse_password" {
  value     = random_password.clickhouse_password.result
  sensitive = true
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "clickhouse_secret_arn" {
  value = aws_secretsmanager_secret.clickhouse.arn
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}
