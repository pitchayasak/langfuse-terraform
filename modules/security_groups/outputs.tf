output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "langfuse_web_sg_id" {
  value = aws_security_group.langfuse_web.id
}

output "langfuse_worker_sg_id" {
  value = aws_security_group.langfuse_worker.id
}

output "redis_client_sg_id" {
  value = aws_security_group.redis_client.id
}

output "redis_server_sg_id" {
  value = aws_security_group.redis_server.id
}

output "clickhouse_client_sg_id" {
  value = aws_security_group.clickhouse_client.id
}

output "clickhouse_server_sg_id" {
  value = aws_security_group.clickhouse_server.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "efs_sg_id" {
  value = aws_security_group.efs.id
}
