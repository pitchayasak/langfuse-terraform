variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "clickhouse_server_sg_id" {
  type = string
}

variable "clickhouse_client_sg_id" {
  type = string
}

variable "task_execution_role_arn" {
  type = string
}

variable "clickhouse_task_role_arn" {
  type = string
}

variable "efs_file_system_id" {
  type = string
}

variable "efs_access_point_id" {
  type = string
}

variable "cloud_map_service_arn" {
  type = string
}

variable "clickhouse_secret_arn" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "clickhouse_image" {
  type = string
}

variable "clickhouse_bucket_name" {
  type = string
}

variable "clickhouse_password" {
  type      = string
  sensitive = true
}

variable "clickhouse_cpu" {
  type = number
}

variable "clickhouse_memory" {
  type = number
}
