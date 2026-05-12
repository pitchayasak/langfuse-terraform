variable "name_prefix" {
  type = string
}

variable "efs_arn" {
  type        = string
  description = "ARN of the EFS file system to back up"
}

variable "backup_retention_days" {
  type        = number
  description = "Number of days to retain EFS backup recovery points"
  default     = 14
}
