output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "clickhouse_log_group_name" {
  value = aws_cloudwatch_log_group.clickhouse.name
}

output "web_log_group_name" {
  value = aws_cloudwatch_log_group.web.name
}

output "worker_log_group_name" {
  value = aws_cloudwatch_log_group.worker.name
}
