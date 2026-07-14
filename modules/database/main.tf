resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-db-subnet-group" }
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name_prefix}-aurora-pg15"
  family      = "aurora-postgresql15"
  description = "Langfuse Aurora PostgreSQL 15 parameter group"

  parameter {
    name  = "log_min_duration_statement"
    value = "15000" # 15 seconds
  }

  parameter {
    name  = "default_transaction_isolation"
    value = "read committed"
  }

  tags = { Name = "${var.name_prefix}-aurora-pg15" }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier     = "${var.name_prefix}-db"
  engine                 = "aurora-postgresql"
  engine_version         = "15"
  database_name          = "langfuse"
  master_username        = "langfuse"
  master_password        = var.db_master_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id]

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  backup_retention_period      = var.db_backup_retention
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "mon:05:00-mon:06:00"

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.name_prefix}-db-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  storage_encrypted = true

  tags = { Name = "${var.name_prefix}-db" }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier           = "${var.name_prefix}-db-writer"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = var.db_instance_class
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name

  auto_minor_version_upgrade = false
  publicly_accessible        = false

  tags = { Name = "${var.name_prefix}-db-writer" }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier           = "${var.name_prefix}-db-reader"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = var.db_instance_class
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name

  auto_minor_version_upgrade = false
  publicly_accessible        = false

  tags = { Name = "${var.name_prefix}-db-reader" }

  depends_on = [aws_rds_cluster_instance.writer]
}

resource "aws_cloudwatch_log_group" "rds" {
  name              = "/aws/rds/cluster/${var.name_prefix}-db/postgresql"
  retention_in_days = var.log_retention_days

  tags = { Name = "${var.name_prefix}-rds-logs" }

  lifecycle {
    ignore_changes = [tags]
  }
}
