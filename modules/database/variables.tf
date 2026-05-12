variable "name_prefix" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_security_group_id" {
  type = string
}

variable "db_instance_class" {
  type = string
}

variable "db_backup_retention" {
  type = number
}

variable "db_deletion_protection" {
  type = bool
}

variable "db_skip_final_snapshot" {
  type = bool
}

variable "db_master_password" {
  type      = string
  sensitive = true
}

variable "log_retention_days" {
  type = number
}
