resource "random_password" "db_password" {
  length  = 32
  special = false
}

resource "random_password" "clickhouse_password" {
  length  = 32
  special = false
}

resource "random_bytes" "salt" {
  length = 32
}

resource "random_bytes" "encryption_key" {
  length = 32
}

resource "random_bytes" "nextauth_secret" {
  length = 32
}

# --- Aurora DB credentials ---
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name_prefix}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "langfuse"
    password = random_password.db_password.result
  })
}

# --- ClickHouse credentials ---
resource "aws_secretsmanager_secret" "clickhouse" {
  name                    = "${var.name_prefix}/clickhouse"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "clickhouse" {
  secret_id = aws_secretsmanager_secret.clickhouse.id
  secret_string = jsonencode({
    db       = "langfuse_system"
    user     = "langfuse"
    password = random_password.clickhouse_password.result
  })
}

# --- Application secrets (SALT, ENCRYPTION_KEY, NEXTAUTH_SECRET) ---
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name_prefix}/app"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    SALT            = random_bytes.salt.hex
    ENCRYPTION_KEY  = random_bytes.encryption_key.hex
    NEXTAUTH_SECRET = random_bytes.nextauth_secret.hex
  })
}
