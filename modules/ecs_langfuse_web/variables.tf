variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "web_sg_id" {
  type = string
}

variable "redis_client_sg_id" {
  type = string
}

variable "clickhouse_client_sg_id" {
  type = string
}

variable "rds_sg_id" {
  type = string
}

variable "task_execution_role_arn" {
  type = string
}

variable "web_task_role_arn" {
  type = string
}

variable "alb_target_group_arn" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "db_cluster_endpoint" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "redis_primary_endpoint" {
  type = string
}

variable "blob_bucket_name" {
  type = string
}

variable "events_bucket_name" {
  type = string
}

variable "app_secret_arn" {
  type = string
}

variable "clickhouse_secret_arn" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "langfuse_web_image" {
  type = string
}

variable "langfuse_cpu" {
  type = number
}

variable "langfuse_memory" {
  type = number
}

variable "web_min_capacity" {
  type = number
}

variable "web_max_capacity" {
  type = number
}

variable "web_cpu_scale_threshold" {
  type = number
}

variable "telemetry_enabled" {
  type = bool
}

variable "experimental_features_enabled" {
  type = bool
}
