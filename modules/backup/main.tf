# -------------------------------------------------------
# AWS Backup for ClickHouse EFS metadata
#
# EFS stores table DDL + S3 pointer files — losing it
# makes S3 data parts inaccessible, so EFS is the
# critical piece to protect with regular backups.
#
# Schedule: daily at 02:00 UTC, retain for
#           var.backup_retention_days (default 14).
# -------------------------------------------------------

resource "aws_backup_vault" "langfuse" {
  name = "${var.name_prefix}-vault"

  tags = { Name = "${var.name_prefix}-vault" }
}

resource "aws_backup_plan" "efs" {
  name = "${var.name_prefix}-efs-daily"

  rule {
    rule_name         = "daily-02-utc"
    target_vault_name = aws_backup_vault.langfuse.name
    schedule          = "cron(0 2 * * ? *)"

    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_retention_days
    }

    recovery_point_tags = { ManagedBy = "terraform" }
  }

  tags = { Name = "${var.name_prefix}-efs-daily" }
}

resource "aws_backup_selection" "efs" {
  name         = "${var.name_prefix}-efs"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.efs.id

  resources = [var.efs_arn]
}

# -------------------------------------------------------
# IAM Role for AWS Backup service
# -------------------------------------------------------
resource "aws_iam_role" "backup" {
  name = "${var.name_prefix}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.name_prefix}-backup" }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}
