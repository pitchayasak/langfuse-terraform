output "blob_bucket_name" {
  value = aws_s3_bucket.blob.bucket
}

output "blob_bucket_arn" {
  value = aws_s3_bucket.blob.arn
}

output "events_bucket_name" {
  value = aws_s3_bucket.events.bucket
}

output "events_bucket_arn" {
  value = aws_s3_bucket.events.arn
}

output "clickhouse_bucket_name" {
  value = aws_s3_bucket.clickhouse.bucket
}

output "clickhouse_bucket_arn" {
  value = aws_s3_bucket.clickhouse.arn
}

output "ecr_web_repo_url" {
  value = aws_ecr_repository.langfuse_web.repository_url
}

output "ecr_worker_repo_url" {
  value = aws_ecr_repository.langfuse_worker.repository_url
}

output "ecr_clickhouse_repo_url" {
  value = aws_ecr_repository.clickhouse.repository_url
}

output "efs_file_system_id" {
  value = aws_efs_file_system.clickhouse.id
}

output "efs_arn" {
  value = aws_efs_file_system.clickhouse.arn
}

output "efs_access_point_id" {
  value = aws_efs_access_point.clickhouse.id
}
