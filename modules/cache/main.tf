resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache-subnet"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-cache-subnet" }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-cache"
  description          = "Langfuse Valkey cache"

  engine         = "valkey"
  engine_version = "7.2"
  node_type      = var.cache_node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.redis_server_sg_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "preferred"

  auto_minor_version_upgrade = false

  snapshot_retention_limit = 3
  snapshot_window          = "19:00-21:00"
  maintenance_window       = "mon:21:00-mon:22:30"

  tags = { Name = "${var.name_prefix}-cache" }
}
