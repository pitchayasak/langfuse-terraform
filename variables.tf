variable "terraform_role_arn" {
  description = "ARN of the IAM role Terraform assumes to deploy. Create it with iam-setup/create-role.sh first."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "langfuse"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to use. Leave empty to auto-select first 3."
  type        = list(string)
  default     = []
}

variable "nat_gateway_count" {
  description = "Number of NAT Gateways to create (1–3). Use 1 to minimize EIP usage and cost; use 3 for full AZ redundancy in production."
  type        = number
  default     = 1
}

# --- Database ---
variable "db_instance_class" {
  description = "Aurora PostgreSQL instance class"
  type        = string
  default     = "db.r6g.large"
}

variable "db_backup_retention" {
  description = "Aurora backup retention in days"
  type        = number
  default     = 3
}

variable "db_deletion_protection" {
  description = "Enable deletion protection on Aurora cluster"
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot on Aurora cluster deletion"
  type        = bool
  default     = true
}

# --- Cache ---
variable "cache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.small"
}

# --- Container images ---
variable "clickhouse_image" {
  description = "ClickHouse container image"
  type        = string
  default     = "clickhouse/clickhouse-server:26.3-alpine"
}

variable "langfuse_web_image" {
  description = "Langfuse web container image"
  type        = string
  default     = "langfuse/langfuse:3"
}

variable "langfuse_worker_image" {
  description = "Langfuse worker container image"
  type        = string
  default     = "langfuse/langfuse-worker:3"
}

# --- ECS sizing ---
variable "clickhouse_cpu" {
  description = "ClickHouse task CPU units"
  type        = number
  default     = 1024
}

variable "clickhouse_memory" {
  description = "ClickHouse task memory (MiB)"
  type        = number
  default     = 8192
}

variable "langfuse_cpu" {
  description = "Langfuse web/worker task CPU units"
  type        = number
  default     = 2048
}

variable "langfuse_memory" {
  description = "Langfuse web/worker task memory (MiB)"
  type        = number
  default     = 4096
}

variable "worker_desired_count" {
  description = "Desired task count for the worker service"
  type        = number
  default     = 1
}

# --- Auto Scaling ---
variable "web_min_capacity" {
  description = "Min tasks for Langfuse web auto-scaling"
  type        = number
  default     = 1
}

variable "web_max_capacity" {
  description = "Max tasks for Langfuse web auto-scaling"
  type        = number
  default     = 2
}

variable "web_cpu_scale_threshold" {
  description = "CPU utilization % to trigger web scale-out"
  type        = number
  default     = 70
}

# --- Backup ---
variable "backup_retention_days" {
  description = "Days to retain EFS (ClickHouse metadata) backup recovery points"
  type        = number
  default     = 14
}

# --- Logging ---
variable "log_retention_days" {
  description = "CloudWatch log retention for ECS services"
  type        = number
  default     = 7
}

variable "rds_log_retention_days" {
  description = "CloudWatch log retention for RDS"
  type        = number
  default     = 3
}

# --- Langfuse app config ---
variable "telemetry_enabled" {
  description = "Enable Langfuse telemetry"
  type        = bool
  default     = false
}

variable "experimental_features_enabled" {
  description = "Enable Langfuse experimental features"
  type        = bool
  default     = false
}
