resource "aws_service_discovery_private_dns_namespace" "langfuse" {
  name = "langfuse.local"
  vpc  = var.vpc_id

  tags = { Name = "langfuse.local" }
}

resource "aws_service_discovery_service" "clickhouse" {
  name = "clickhouse"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.langfuse.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = { Name = "clickhouse.langfuse.local" }
}
