locals {
  database_url             = "postgresql://langfuse:${var.db_password}@${var.db_cluster_endpoint}:5432/langfuse"
  redis_url                = "rediss://${var.redis_primary_endpoint}:6379"
  clickhouse_url           = "http://clickhouse.langfuse.local:8123"
  clickhouse_migration_url = "clickhouse://clickhouse.langfuse.local:9000/langfuse"

  container_definitions = jsonencode([
    {
      name  = "langfuse-web"
      image = var.langfuse_web_image

      portMappings = [
        { containerPort = 3000, protocol = "tcp" }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "NEXTAUTH_URL", value = "http://${var.alb_dns_name}" },
        { name = "DATABASE_URL", value = local.database_url },
        { name = "REDIS_CONNECTION_STRING", value = local.redis_url },
        { name = "CLICKHOUSE_URL", value = local.clickhouse_url },
        { name = "CLICKHOUSE_MIGRATION_URL", value = local.clickhouse_migration_url },
        { name = "CLICKHOUSE_USER", value = "langfuse" },
        { name = "LANGFUSE_S3_MEDIA_UPLOAD_BUCKET", value = var.blob_bucket_name },
        { name = "LANGFUSE_S3_BATCH_EXPORT_BUCKET", value = var.events_bucket_name },
        { name = "LANGFUSE_S3_EVENT_UPLOAD_BUCKET", value = var.events_bucket_name },
        { name = "LANGFUSE_S3_MEDIA_UPLOAD_PREFIX", value = "" },
        { name = "LANGFUSE_S3_BATCH_EXPORT_PREFIX", value = "exports/" },
        { name = "LANGFUSE_S3_EVENT_UPLOAD_PREFIX", value = "events/" },
        { name = "LANGFUSE_S3_MEDIA_UPLOAD_REGION", value = var.aws_region },
        { name = "LANGFUSE_S3_BATCH_EXPORT_REGION", value = var.aws_region },
        { name = "LANGFUSE_S3_EVENT_UPLOAD_REGION", value = var.aws_region },
        { name = "BATCH_EXPORT_ENABLED", value = "true" },
        { name = "MEDIA_UPLOAD_ENABLED", value = "true" },
        { name = "S3_MEDIA_MAX_LENGTH_SECONDS", value = "604800" },
        { name = "TELEMETRY_ENABLED", value = tostring(var.telemetry_enabled) },
        { name = "LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES", value = tostring(var.experimental_features_enabled) },
      ]

      secrets = [
        { name = "SALT", valueFrom = "${var.app_secret_arn}:SALT::" },
        { name = "ENCRYPTION_KEY", valueFrom = "${var.app_secret_arn}:ENCRYPTION_KEY::" },
        { name = "NEXTAUTH_SECRET", valueFrom = "${var.app_secret_arn}:NEXTAUTH_SECRET::" },
        { name = "CLICKHOUSE_PASSWORD", valueFrom = "${var.clickhouse_secret_arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "web"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "web" {
  family                   = "${var.name_prefix}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.langfuse_cpu
  memory                   = var.langfuse_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.web_task_role_arn

  container_definitions = local.container_definitions

  tags = { Name = "${var.name_prefix}-web" }
}

resource "aws_ecs_service" "web" {
  name            = "${var.name_prefix}-web"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.web_min_capacity
  launch_type     = "FARGATE"

  network_configuration {
    subnets = var.private_subnet_ids
    security_groups = [
      var.web_sg_id,
      var.redis_client_sg_id,
      var.clickhouse_client_sg_id,
      var.rds_sg_id,
    ]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_target_group_arn
    container_name   = "langfuse-web"
    container_port   = 3000
  }

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  enable_execute_command = true

  tags = { Name = "${var.name_prefix}-web" }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# --- Auto Scaling ---
resource "aws_appautoscaling_target" "web" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.name_prefix}-web"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.web_min_capacity
  max_capacity       = var.web_max_capacity

  depends_on = [aws_ecs_service.web]
}

resource "aws_appautoscaling_policy" "web_cpu" {
  name               = "${var.name_prefix}-web-cpu-scaling"
  service_namespace  = aws_appautoscaling_target.web.service_namespace
  resource_id        = aws_appautoscaling_target.web.resource_id
  scalable_dimension = aws_appautoscaling_target.web.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.web_cpu_scale_threshold
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}
