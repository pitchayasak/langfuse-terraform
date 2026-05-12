output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.langfuse.id
}

output "clickhouse_service_arn" {
  value = aws_service_discovery_service.clickhouse.arn
}
