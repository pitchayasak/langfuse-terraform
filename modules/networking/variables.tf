variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = []
}

variable "aws_region" {
  type = string
}

variable "nat_gateway_count" {
  type        = number
  description = "Number of NAT Gateways to create (1–3). Use 1 to minimize EIP usage and cost; use 3 for full AZ redundancy in production."
  default     = 1
}
