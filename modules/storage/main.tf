data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# -------------------------------------------------------
# S3 Buckets
# -------------------------------------------------------
resource "aws_s3_bucket" "blob" {
  bucket        = "${var.name_prefix}-blob-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name_prefix}-blob" }
}

resource "aws_s3_bucket" "events" {
  bucket        = "${var.name_prefix}-events-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name_prefix}-events" }
}

resource "aws_s3_bucket_versioning" "blob" {
  bucket = aws_s3_bucket.blob.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_versioning" "events" {
  bucket = aws_s3_bucket.events.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "blob" {
  bucket = aws_s3_bucket.blob.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events" {
  bucket = aws_s3_bucket.events.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "blob" {
  bucket                  = aws_s3_bucket.blob.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "events" {
  bucket                  = aws_s3_bucket.events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ClickHouse data bucket — versioning intentionally disabled.
# ClickHouse manages its own data lifecycle (part merges, mutations, TTL),
# and S3 versioning causes "ghost" versions that waste space and break deletes.
resource "aws_s3_bucket" "clickhouse" {
  bucket        = "${var.name_prefix}-clickhouse-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name_prefix}-clickhouse" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clickhouse" {
  bucket = aws_s3_bucket.clickhouse.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "clickhouse" {
  bucket                  = aws_s3_bucket.clickhouse.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------------------------------------
# ECR Repositories
# -------------------------------------------------------
resource "aws_ecr_repository" "langfuse_web" {
  name                 = "${var.name_prefix}-web"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }

  tags = { Name = "${var.name_prefix}-web" }
}

resource "aws_ecr_repository" "langfuse_worker" {
  name                 = "${var.name_prefix}-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }

  tags = { Name = "${var.name_prefix}-worker" }
}

resource "aws_ecr_repository" "clickhouse" {
  name                 = "${var.name_prefix}-clickhouse"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }

  tags = { Name = "${var.name_prefix}-clickhouse" }
}

resource "aws_ecr_lifecycle_policy" "langfuse_web" {
  repository = aws_ecr_repository.langfuse_web.name
  policy = jsonencode({
    rules = [
      { rulePriority = 1, description = "Remove untagged after 7 days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }, action = { type = "expire" } },
      { rulePriority = 2, description = "Keep last 3 images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 3 }, action = { type = "expire" } },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "langfuse_worker" {
  repository = aws_ecr_repository.langfuse_worker.name
  policy = jsonencode({
    rules = [
      { rulePriority = 1, description = "Remove untagged after 7 days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }, action = { type = "expire" } },
      { rulePriority = 2, description = "Keep last 3 images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 3 }, action = { type = "expire" } },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "clickhouse" {
  repository = aws_ecr_repository.clickhouse.name
  policy = jsonencode({
    rules = [
      { rulePriority = 1, description = "Remove untagged after 7 days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }, action = { type = "expire" } },
      { rulePriority = 2, description = "Keep last 3 images", selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 3 }, action = { type = "expire" } },
    ]
  })
}

# -------------------------------------------------------
# EFS for ClickHouse data persistence
# -------------------------------------------------------
resource "aws_efs_file_system" "clickhouse" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = { Name = "${var.name_prefix}-clickhouse-data" }
}

resource "aws_efs_mount_target" "clickhouse" {
  count = length(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.clickhouse.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [var.efs_security_group_id]
}

# ClickHouse runs as UID/GID 101
resource "aws_efs_access_point" "clickhouse" {
  file_system_id = aws_efs_file_system.clickhouse.id

  posix_user {
    uid = 101
    gid = 101
  }

  root_directory {
    path = "/clickhouse"
    creation_info {
      owner_uid   = 101
      owner_gid   = 101
      permissions = "755"
    }
  }

  tags = { Name = "${var.name_prefix}-clickhouse-ap" }
}
