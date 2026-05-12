variable "name_prefix" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "redis_server_sg_id" {
  type = string
}

variable "cache_node_type" {
  type = string
}
