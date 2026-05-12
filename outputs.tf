output "langfuse_url" {
  description = "Langfuse application URL"
  value       = "http://${module.load_balancer.alb_dns_name}"
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.load_balancer.alb_dns_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.ecs_cluster.cluster_name
}

output "rds_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.database.cluster_endpoint
}

output "rds_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = module.database.cluster_reader_endpoint
}

output "ecr_web_repo_url" {
  description = "ECR repository URL for langfuse-web"
  value       = module.storage.ecr_web_repo_url
}

output "ecr_worker_repo_url" {
  description = "ECR repository URL for langfuse-worker"
  value       = module.storage.ecr_worker_repo_url
}

output "ecr_clickhouse_repo_url" {
  description = "ECR repository URL for clickhouse"
  value       = module.storage.ecr_clickhouse_repo_url
}

output "s3_blob_bucket_name" {
  description = "S3 bucket for media/blob storage"
  value       = module.storage.blob_bucket_name
}

output "s3_events_bucket_name" {
  description = "S3 bucket for events and batch exports"
  value       = module.storage.events_bucket_name
}
