locals {
  # ----------------------------------------------------------
  # ClickHouse custom config injected at container startup:
  #
  # 1. storage_configuration — S3 as primary data disk.
  #    EFS (mounted at /var/lib/clickhouse) stores only:
  #      - table metadata files  (/var/lib/clickhouse/metadata/)
  #      - S3 disk metadata refs (/var/lib/clickhouse/disks/s3_disk/)
  #      - temporary query files (/var/lib/clickhouse/tmp/)
  #
  # 2. merge_tree — sets s3_main as the default storage policy
  #    for all MergeTree tables, so Langfuse migrations use S3
  #    automatically without needing STORAGE POLICY per table.
  #
  # 3. remote_servers — single-shard cluster definition.
  #    shards: 1 / replicas: 1 (single node).
  #
  # 4. macros — {cluster}, {shard}, {replica} substitution
  #    used by Langfuse DDL when ON CLUSTER is specified.
  #
  # 5. keeper_server — embedded ClickHouse Keeper (replaces
  #    ZooKeeper). Required for ReplicatedMergeTree tables
  #    that Langfuse migrations create via ON CLUSTER DDL.
  #    Runs inside the same container on localhost:9181.
  #    Coordination data stored on EFS at
  #    /var/lib/clickhouse/coordination/ (backed up daily).
  #
  # 6. zookeeper — points ClickHouse's replication layer to
  #    the embedded Keeper on localhost:9181.
  # ----------------------------------------------------------
  clickhouse_config = <<-XML
<clickhouse>
    <logger>
        <console>1</console>
        <level>warning</level>
    </logger>
    <storage_configuration>
        <disks>
            <s3_disk>
                <type>s3</type>
                <endpoint>https://${var.clickhouse_bucket_name}.s3.${var.aws_region}.amazonaws.com/data/</endpoint>
                <use_environment_credentials>1</use_environment_credentials>
                <metadata_path>/var/lib/clickhouse/disks/s3_disk/</metadata_path>
            </s3_disk>
        </disks>
        <policies>
            <s3_main>
                <volumes>
                    <main>
                        <disk>s3_disk</disk>
                    </main>
                </volumes>
            </s3_main>
        </policies>
    </storage_configuration>
    <merge_tree>
        <storage_policy>s3_main</storage_policy>
    </merge_tree>
    <remote_servers>
        <langfuse_cluster>
            <shard>
                <weight>1</weight>
                <internal_replication>false</internal_replication>
                <replica>
                    <host>clickhouse.langfuse.local</host>
                    <port>9000</port>
                    <user>langfuse</user>
                    <password>${var.clickhouse_password}</password>
                </replica>
            </shard>
        </langfuse_cluster>
    </remote_servers>
    <macros>
        <cluster>langfuse_cluster</cluster>
        <shard>01</shard>
        <replica>01</replica>
    </macros>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
        </coordination_settings>
        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>localhost</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
    <zookeeper>
        <node>
            <host>localhost</host>
            <port>9181</port>
        </node>
    </zookeeper>
</clickhouse>
XML

  clickhouse_config_b64 = base64encode(local.clickhouse_config)

  # Startup command:
  # 1. Write the custom config (base64-decoded) to config.d/
  # 2. exec replaces bash with /entrypoint.sh so ClickHouse
  #    runs as PID 1 and handles SIGTERM correctly.
  startup_command = "mkdir -p /etc/clickhouse-server/config.d && printf '%s' '${local.clickhouse_config_b64}' | base64 -d > /etc/clickhouse-server/config.d/s3_storage.xml && rm -f /var/lib/clickhouse/status && exec /entrypoint.sh"

  container_definitions = jsonencode([
    {
      name  = "clickhouse"
      image = var.clickhouse_image

      # Override entryPoint so we can inject config before ClickHouse starts
      # Alpine has /bin/sh (not bash) — use sh -c instead
      entryPoint = ["/bin/sh", "-c"]
      command    = [local.startup_command]

      portMappings = [
        { containerPort = 8123, protocol = "tcp" },
        { containerPort = 9000, protocol = "tcp" },
      ]

      # EFS mount — metadata only (data parts go to S3)
      mountPoints = [
        {
          sourceVolume  = "clickhouse-metadata"
          containerPath = "/var/lib/clickhouse"
          readOnly      = false
        }
      ]

      environment = [
        { name = "CLICKHOUSE_DB", value = "langfuse" },
        { name = "CLICKHOUSE_USER", value = "langfuse" },
      ]

      secrets = [
        {
          name      = "CLICKHOUSE_PASSWORD"
          valueFrom = "${var.clickhouse_secret_arn}:password::"
        }
      ]

      ulimits = [
        { name = "nofile", softLimit = 262144, hardLimit = 262144 }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8123/ping || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "clickhouse"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "clickhouse" {
  family                   = "${var.name_prefix}-clickhouse"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.clickhouse_cpu
  memory                   = var.clickhouse_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.clickhouse_task_role_arn

  container_definitions = local.container_definitions

  # EFS volume — stores metadata only; actual data parts live on S3
  volume {
    name = "clickhouse-metadata"

    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  tags = { Name = "${var.name_prefix}-clickhouse" }
}

resource "aws_ecs_service" "clickhouse" {
  name            = "${var.name_prefix}-clickhouse"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.clickhouse.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # EFS mounts require platform version 1.4.0
  platform_version = "1.4.0"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.clickhouse_server_sg_id, var.clickhouse_client_sg_id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = var.cloud_map_service_arn
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  enable_execute_command = true

  tags = { Name = "${var.name_prefix}-clickhouse" }

  lifecycle {
    ignore_changes = [task_definition]
  }
}
