resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache-subnet"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "${var.name_prefix}-cache-subnet" }
}

# BullMQ (used by the Langfuse worker for job queues) requires Redis/Valkey to
# never evict keys under memory pressure — the default parameter group ships
# with "volatile-lru", which silently drops queue data instead of erroring.
resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.name_prefix}-cache-params"
  family = "valkey7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  tags = { Name = "${var.name_prefix}-cache-params" }
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

  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [var.redis_server_sg_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "preferred"

  auto_minor_version_upgrade = false

  snapshot_retention_limit = 3
  snapshot_window          = "19:00-21:00"
  maintenance_window       = "mon:21:00-mon:22:30"

  tags = { Name = "${var.name_prefix}-cache" }
}
