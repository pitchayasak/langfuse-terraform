# --- ALB ---
resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  vpc_id      = var.vpc_id
  description = "ALB: allow HTTP/HTTPS from internet"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Langfuse Web ---
resource "aws_security_group" "langfuse_web" {
  name_prefix = "${var.name_prefix}-web-"
  vpc_id      = var.vpc_id
  description = "Langfuse web: allow port 3000 from VPC"

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-web-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Langfuse Worker ---
resource "aws_security_group" "langfuse_worker" {
  name_prefix = "${var.name_prefix}-worker-"
  vpc_id      = var.vpc_id
  description = "Langfuse worker: allow all TCP from VPC"

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-worker-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Redis client (attached to web/worker tasks) ---
resource "aws_security_group" "redis_client" {
  name_prefix = "${var.name_prefix}-redis-client-"
  vpc_id      = var.vpc_id
  description = "Redis client: allows outbound to Redis server"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-redis-client-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Redis server (attached to ElastiCache) ---
resource "aws_security_group" "redis_server" {
  name_prefix = "${var.name_prefix}-redis-server-"
  vpc_id      = var.vpc_id
  description = "Redis server: allow port 6379 from client SG"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-redis-server-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "redis_server_ingress" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis_server.id
  source_security_group_id = aws_security_group.redis_client.id
  description              = "Allow Redis from client SG"
}

# --- ClickHouse client (attached to web/worker tasks) ---
resource "aws_security_group" "clickhouse_client" {
  name_prefix = "${var.name_prefix}-ch-client-"
  vpc_id      = var.vpc_id
  description = "ClickHouse client: allows outbound to ClickHouse"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-clickhouse-client-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- ClickHouse server (attached to ClickHouse ECS task) ---
resource "aws_security_group" "clickhouse_server" {
  name_prefix = "${var.name_prefix}-ch-server-"
  vpc_id      = var.vpc_id
  description = "ClickHouse server: allow 8123/9000 from client SG"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-clickhouse-server-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "clickhouse_server_http" {
  type                     = "ingress"
  from_port                = 8123
  to_port                  = 8123
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse_server.id
  source_security_group_id = aws_security_group.clickhouse_client.id
  description              = "ClickHouse HTTP from client SG"
}

resource "aws_security_group_rule" "clickhouse_server_native" {
  type                     = "ingress"
  from_port                = 9000
  to_port                  = 9000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse_server.id
  source_security_group_id = aws_security_group.clickhouse_client.id
  description              = "ClickHouse native from client SG"
}

# --- RDS ---
resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  vpc_id      = var.vpc_id
  description = "RDS: allow PostgreSQL port 5432 from VPC"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- EFS ---
resource "aws_security_group" "efs" {
  name_prefix = "${var.name_prefix}-efs-"
  vpc_id      = var.vpc_id
  description = "EFS: allow NFS port 2049 from VPC"

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-efs-sg" }

  lifecycle {
    create_before_destroy = true
  }
}
