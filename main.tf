module "networking" {
  source = "./modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  aws_region         = var.aws_region

  nat_gateway_count = var.nat_gateway_count
}

module "security_groups" {
  source = "./modules/security_groups"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  vpc_cidr    = var.vpc_cidr
}

module "iam" {
  source = "./modules/iam"

  name_prefix           = local.name_prefix
  aws_region            = var.aws_region
  blob_bucket_arn       = module.storage.blob_bucket_arn
  events_bucket_arn     = module.storage.events_bucket_arn
  efs_arn               = module.storage.efs_arn
  clickhouse_bucket_arn = module.storage.clickhouse_bucket_arn
}

module "secrets" {
  source = "./modules/secrets"

  name_prefix = local.name_prefix
}

module "storage" {
  source = "./modules/storage"

  name_prefix           = local.name_prefix
  aws_region            = var.aws_region
  private_subnet_ids    = module.networking.private_subnet_ids
  efs_security_group_id = module.security_groups.efs_sg_id
}

module "database" {
  source = "./modules/database"

  name_prefix            = local.name_prefix
  private_subnet_ids     = module.networking.private_subnet_ids
  rds_security_group_id  = module.security_groups.rds_sg_id
  db_instance_class      = var.db_instance_class
  db_backup_retention    = var.db_backup_retention
  db_deletion_protection = var.db_deletion_protection
  db_skip_final_snapshot = var.db_skip_final_snapshot
  db_master_password     = module.secrets.db_password
  log_retention_days     = var.rds_log_retention_days
}

module "cache" {
  source = "./modules/cache"

  name_prefix        = local.name_prefix
  private_subnet_ids = module.networking.private_subnet_ids
  redis_server_sg_id = module.security_groups.redis_server_sg_id
  cache_node_type    = var.cache_node_type
}

module "service_discovery" {
  source = "./modules/service_discovery"

  vpc_id = module.networking.vpc_id
}

module "load_balancer" {
  source = "./modules/load_balancer"

  name_prefix       = local.name_prefix
  public_subnet_ids = module.networking.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
  vpc_id            = module.networking.vpc_id
}

module "ecs_cluster" {
  source = "./modules/ecs_cluster"

  name_prefix            = local.name_prefix
  log_retention_days     = var.log_retention_days
  rds_log_retention_days = var.rds_log_retention_days
}

module "ecs_clickhouse" {
  source = "./modules/ecs_clickhouse"

  name_prefix              = local.name_prefix
  aws_region               = var.aws_region
  cluster_id               = module.ecs_cluster.cluster_id
  private_subnet_ids       = module.networking.private_subnet_ids
  clickhouse_server_sg_id  = module.security_groups.clickhouse_server_sg_id
  clickhouse_client_sg_id  = module.security_groups.clickhouse_client_sg_id
  task_execution_role_arn  = module.iam.task_execution_role_arn
  clickhouse_task_role_arn = module.iam.clickhouse_task_role_arn
  efs_file_system_id       = module.storage.efs_file_system_id
  efs_access_point_id      = module.storage.efs_access_point_id
  cloud_map_service_arn    = module.service_discovery.clickhouse_service_arn
  clickhouse_secret_arn    = module.secrets.clickhouse_secret_arn
  log_group_name           = module.ecs_cluster.clickhouse_log_group_name
  clickhouse_image         = var.clickhouse_image
  clickhouse_cpu           = var.clickhouse_cpu
  clickhouse_memory        = var.clickhouse_memory
  clickhouse_bucket_name   = module.storage.clickhouse_bucket_name
  clickhouse_password      = module.secrets.clickhouse_password
}

module "ecs_langfuse_web" {
  source = "./modules/ecs_langfuse_web"

  name_prefix                   = local.name_prefix
  aws_region                    = var.aws_region
  cluster_id                    = module.ecs_cluster.cluster_id
  cluster_name                  = module.ecs_cluster.cluster_name
  private_subnet_ids            = module.networking.private_subnet_ids
  web_sg_id                     = module.security_groups.langfuse_web_sg_id
  redis_client_sg_id            = module.security_groups.redis_client_sg_id
  clickhouse_client_sg_id       = module.security_groups.clickhouse_client_sg_id
  rds_sg_id                     = module.security_groups.rds_sg_id
  task_execution_role_arn       = module.iam.task_execution_role_arn
  web_task_role_arn             = module.iam.web_task_role_arn
  alb_target_group_arn          = module.load_balancer.target_group_arn
  alb_dns_name                  = module.load_balancer.alb_dns_name
  db_cluster_endpoint           = module.database.cluster_endpoint
  db_password                   = module.secrets.db_password
  redis_primary_endpoint        = module.cache.primary_endpoint
  blob_bucket_name              = module.storage.blob_bucket_name
  events_bucket_name            = module.storage.events_bucket_name
  app_secret_arn                = module.secrets.app_secret_arn
  clickhouse_secret_arn         = module.secrets.clickhouse_secret_arn
  log_group_name                = module.ecs_cluster.web_log_group_name
  langfuse_web_image            = var.langfuse_web_image
  langfuse_cpu                  = var.langfuse_cpu
  langfuse_memory               = var.langfuse_memory
  web_min_capacity              = var.web_min_capacity
  web_max_capacity              = var.web_max_capacity
  web_cpu_scale_threshold       = var.web_cpu_scale_threshold
  telemetry_enabled             = var.telemetry_enabled
  experimental_features_enabled = var.experimental_features_enabled
}

module "backup" {
  source = "./modules/backup"

  name_prefix           = local.name_prefix
  efs_arn               = module.storage.efs_arn
  backup_retention_days = var.backup_retention_days
}

module "ecs_langfuse_worker" {
  source = "./modules/ecs_langfuse_worker"

  name_prefix                   = local.name_prefix
  aws_region                    = var.aws_region
  cluster_id                    = module.ecs_cluster.cluster_id
  private_subnet_ids            = module.networking.private_subnet_ids
  worker_sg_id                  = module.security_groups.langfuse_worker_sg_id
  redis_client_sg_id            = module.security_groups.redis_client_sg_id
  clickhouse_client_sg_id       = module.security_groups.clickhouse_client_sg_id
  rds_sg_id                     = module.security_groups.rds_sg_id
  task_execution_role_arn       = module.iam.task_execution_role_arn
  worker_task_role_arn          = module.iam.worker_task_role_arn
  db_cluster_endpoint           = module.database.cluster_endpoint
  db_password                   = module.secrets.db_password
  redis_primary_endpoint        = module.cache.primary_endpoint
  blob_bucket_name              = module.storage.blob_bucket_name
  events_bucket_name            = module.storage.events_bucket_name
  app_secret_arn                = module.secrets.app_secret_arn
  clickhouse_secret_arn         = module.secrets.clickhouse_secret_arn
  log_group_name                = module.ecs_cluster.worker_log_group_name
  langfuse_worker_image         = var.langfuse_worker_image
  langfuse_cpu                  = var.langfuse_cpu
  langfuse_memory               = var.langfuse_memory
  worker_desired_count          = var.worker_desired_count
  telemetry_enabled             = var.telemetry_enabled
  experimental_features_enabled = var.experimental_features_enabled
}
