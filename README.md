# Langfuse v3 — Terraform on AWS ECS Fargate

Self-hosted [Langfuse](https://langfuse.com) v3 deployed on AWS ECS Fargate.  
Infrastructure managed entirely with Terraform.

---

## Architecture

| Component | Service | Config |
|---|---|---|
| Web app | ECS Fargate | 2 vCPU / 4 GB, auto-scale 1→2 tasks |
| Worker | ECS Fargate | 2 vCPU / 4 GB, 1 task |
| ClickHouse | ECS Fargate | 1 vCPU / 8 GB, 1 task |
| PostgreSQL | Aurora PostgreSQL 15.4 | db.r6g.large, 1 writer + 1 reader |
| Redis | ElastiCache Valkey 7.2 | cache.t3.small |
| ClickHouse data | S3 | Data parts (versioning disabled) |
| ClickHouse metadata | EFS | DDL + S3 pointer files |
| Media / Events | S3 x2 | Versioning enabled |
| DNS (internal) | AWS Cloud Map | `clickhouse.langfuse.local` |
| Load balancer | ALB | HTTP :80 → ECS :3000 |
| Backup | AWS Backup | EFS daily snapshot, 14-day retention |

---

## Prerequisites

- AWS CLI configured with credentials that have `iam:CreateRole` / `iam:AttachRolePolicy`
- Terraform >= 1.6.0
- **(Windows)** If Terraform crashes with a TLS/certificate error, run all `terraform` commands inside **WSL2** — some antivirus products (e.g. Norton) intercept the local gRPC connection between Terraform core and provider plugins. WSL2 bypasses the interception.

---

## Step 1 — Create the Deployer IAM Role

Terraform assumes a dedicated IAM role (`langfuse-terraform-deployer`) to deploy.  
Run this **once** with your admin credentials before touching Terraform.

```cmd
# Windows
iam-setup\create-role.cmd

# Custom role name (optional)
iam-setup\create-role.cmd my-custom-role-name
```

The script will:
1. Read your current AWS caller identity
2. Create two managed policies (`langfuse-terraform-networking-storage`, `langfuse-terraform-app-services`)
3. Create the role with a trust policy allowing your current identity to assume it
4. Attach both policies to the role
5. Print the role ARN at the end

Copy the printed ARN — you will need it in Step 2.

To clean up the role later:

```cmd
iam-setup\delete-role.cmd
```

---

## Step 2 — Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at minimum:

```hcl
terraform_role_arn = "arn:aws:iam::<ACCOUNT_ID>:role/langfuse-terraform-deployer"
aws_region         = "us-east-1"
```

All other values have sensible defaults. Key options:

| Variable | Default | Description |
|---|---|---|
| `environment` | `"prod"` | Appended to every resource name |
| `vpc_cidr` | `"10.0.0.0/16"` | CIDR block for the new VPC |
| `nat_gateway_count` | `1` | NAT Gateways (1 = cost-saving, 3 = full AZ redundancy) |
| `db_instance_class` | `"db.r6g.large"` | Aurora instance size |
| `cache_node_type` | `"cache.t3.small"` | ElastiCache node size |
| `clickhouse_image` | `"clickhouse/clickhouse-server:26.3-alpine"` | ClickHouse Docker image |
| `langfuse_web_image` | `"langfuse/langfuse:3"` | Langfuse web Docker image |
| `langfuse_worker_image` | `"langfuse/langfuse-worker:3"` | Langfuse worker Docker image |
| `clickhouse_cpu` | `1024` | ClickHouse Fargate CPU units |
| `clickhouse_memory` | `8192` | ClickHouse Fargate memory (MiB) |
| `web_min_capacity` | `1` | Min web tasks |
| `web_max_capacity` | `2` | Max web tasks (auto-scale) |
| `backup_retention_days` | `14` | Days to keep EFS backups |
| `log_retention_days` | `7` | CloudWatch log retention |

---

## Step 3 — Deploy

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

> **หากเจอ error `ResourceAlreadyExistsException` สำหรับ RDS log group** ให้ดู [Step 4 — Import RDS Log Group](#step-4--import-rds-log-group) แล้วรัน `terraform apply -auto-approve` ต่อ

After apply completes (≈ 15–20 minutes), Terraform prints:

```
langfuse_url = "http://<alb-dns-name>"
```

Open that URL in a browser and complete the initial admin setup.

### Verify the deployment

```bash
curl http://<alb-dns-name>/api/public/health
# Expected: {"status":"ok"}
```

---

## Credentials (Database & ClickHouse)

Password ทั้งหมดถูก generate อัตโนมัติตอน `terraform apply` และเก็บใน **AWS Secrets Manager** Username ของทุก service คือ `langfuse`

| Service | Secret name | Keys |
|---|---|---|
| Aurora PostgreSQL | `langfuse-prod/db` | `username`, `password` |
| ClickHouse | `langfuse-prod/clickhouse` | `user`, `password`, `db` |
| App secrets | `langfuse-prod/app` | `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET` |

> ชื่อ secret ขึ้นต้นด้วย `{project_name}-{environment}` ตามที่ตั้งใน `terraform.tfvars`  
> เช่น ถ้า `project_name = "langfuse"` และ `environment = "prod"` จะได้ `langfuse-prod/db`

**ดู credentials ด้วย AWS CLI:**

```bash
REGION=ap-southeast-1
PREFIX=langfuse-prod   # project_name + environment

# Aurora PostgreSQL
aws secretsmanager get-secret-value \
  --secret-id "$PREFIX/db" \
  --region $REGION \
  --query SecretString --output text
# {"username":"langfuse","password":"xxxx..."}

# ClickHouse
aws secretsmanager get-secret-value \
  --secret-id "$PREFIX/clickhouse" \
  --region $REGION \
  --query SecretString --output text
# {"db":"langfuse","user":"langfuse","password":"xxxx..."}
```

**ดูผ่าน AWS Console:**

`Secrets Manager` → ค้นหาชื่อ secret → **Retrieve secret value**

---

## Step 4 — Import RDS Log Group

Aurora สร้าง CloudWatch log group อัตโนมัติเมื่อ cluster เริ่มเขียน log ทำให้ Terraform ไม่สามารถสร้างซ้ำได้ ต้อง import เข้า state ก่อนจึงจะ apply ต่อได้

```bash
terraform import module.database.aws_cloudwatch_log_group.rds \
  /aws/rds/cluster/<project_name>-<environment>-db/postgresql
```

ตัวอย่าง (ใช้ค่า default `project_name = "langfuse"`, `environment = "prod"`):
```bash
terraform import module.database.aws_cloudwatch_log_group.rds \
  /aws/rds/cluster/langfuse-prod-db/postgresql
```

แล้ว apply ต่อ:
```bash
terraform apply -auto-approve
```

> **หมายเหตุ:** ต้องทำขั้นตอนนี้ทุกครั้งที่รัน `terraform apply` ครั้งแรกหลังสร้าง Aurora cluster ใหม่ (รวมถึงหลัง `terraform destroy` แล้วสร้างใหม่)

---

## Step 5 — Push Custom Images to ECR (optional)

Terraform creates three ECR repositories. To use them instead of public Docker Hub images:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

# Authenticate
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com

# Tag and push
docker pull langfuse/langfuse:3
docker tag langfuse/langfuse:3 $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/langfuse-prod-web:3
docker push $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/langfuse-prod-web:3
```

Then update `terraform.tfvars`:

```hcl
langfuse_web_image    = "<account>.dkr.ecr.us-east-1.amazonaws.com/langfuse-prod-web:3"
langfuse_worker_image = "<account>.dkr.ecr.us-east-1.amazonaws.com/langfuse-prod-worker:3"
clickhouse_image      = "<account>.dkr.ecr.us-east-1.amazonaws.com/langfuse-prod-clickhouse:26.3-alpine"
```

And run `terraform apply` again.

---

## Destroy

```bash
terraform destroy
```

> S3 buckets have `force_destroy = true` — all objects will be deleted permanently.  
> Secrets Manager secrets have `recovery_window_in_days = 0` — deleted immediately.

### เก็บ AWS Backup snapshots ไว้หลัง destroy

โดย default `terraform destroy` จะพยายามลบ backup vault แต่จะ **error** ถ้ายังมี recovery points อยู่ข้างใน (`Non-empty backup vault`)

ถ้าต้องการเก็บ snapshots ไว้ ให้ detach vault ออกจาก Terraform state ก่อน destroy:

```bash
terraform state rm module.backup.aws_backup_vault.langfuse
terraform state rm module.backup.aws_backup_plan.efs
terraform state rm module.backup.aws_backup_selection.efs
```

แล้วค่อย destroy:
```bash
terraform destroy
```

Vault และ recovery points จะยังอยู่ใน AWS ลบด้วยมือได้ภายหลังผ่าน AWS Console หรือ CLI:
```bash
# ลบ recovery points ทั้งหมดก่อน แล้วค่อยลบ vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <prefix>-vault --region <region> \
  --query 'RecoveryPoints[].RecoveryPointArn' --output text | \
  tr '\t' '\n' | xargs -I{} aws backup delete-recovery-point \
  --backup-vault-name <prefix>-vault --recovery-point-arn {} --region <region>

aws backup delete-backup-vault --backup-vault-name <prefix>-vault --region <region>
```


---

## Backup and Recovery

### กลยุทธ์ Backup (Layered Strategy)

ระบบนี้มีข้อมูลอยู่สองที่ที่ต้องป้องกันต่างกัน:

| ชั้นข้อมูล | ที่เก็บ | ความเสี่ยง | วิธีป้องกัน |
|---|---|---|---|
| **ClickHouse data parts** | S3 (`langfuse-prod-clickhouse-*`) | ต่ำ — S3 ทน 11 nines, multi-AZ ในตัว | ไม่จำเป็นต้อง backup เพิ่ม |
| **ClickHouse metadata** | EFS (`/var/lib/clickhouse/metadata/`, `/disks/s3_disk/`) | **สูง** — ถ้าหาย S3 data อ่านไม่ได้ | AWS Backup ทุกวัน |
| **PostgreSQL** | Aurora | ต่ำ — Aurora มี automated backup + PITR ในตัว | `db_backup_retention = 3` วัน (ปรับได้) |
| **Secrets** | Secrets Manager | ต่ำ — managed service, HA ในตัว | ไม่จำเป็น |

**ความสัมพันธ์ที่ต้องเข้าใจ:**

```
S3 data parts  ──────────────────────────────  ทนทานสูง (ไม่ต้อง backup)
      ↑
      │  ← EFS pointer files ชี้ว่าแต่ละ part อยู่ที่ path ไหนบน S3
      │
EFS metadata  ──── AWS Backup (daily) ──────  critical path
```

> ถ้า EFS หาย แต่ S3 ยังอยู่ — ข้อมูลบน S3 **กู้คืนไม่ได้** โดยตรง  
> เพราะ ClickHouse ไม่รู้ว่าแต่ละ data part อยู่ที่ path ไหน

**แนวทางที่แนะนำสำหรับ production:**

```
ทุกวัน  02:00 UTC  ─── AWS Backup snapshot EFS อัตโนมัติ (เก็บ 14 วัน)
ทุกสัปดาห์         ─── ClickHouse BACKUP DATABASE → S3 (manual หรือ scheduled)
ก่อน schema migration ── ClickHouse BACKUP DATABASE → S3 ทุกครั้ง
```

---

### AWS Backup (EFS metadata — automatic)

EFS stores ClickHouse table DDL and S3 pointer files. Losing it makes S3 data inaccessible, so it is backed up automatically every day at 02:00 UTC.

**View recovery points:**

```bash
# List backup vaults
aws backup list-backup-vaults

# List recovery points for the EFS vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name langfuse-prod-vault \
  --query 'RecoveryPoints[*].{Date:CreationDate,Status:Status,ARN:RecoveryPointArn}' \
  --output table
```

**Restore EFS from a recovery point:**

```bash
# 1. Find the recovery point ARN from the command above

# 2. Get the EFS file system ID
EFS_ID=$(terraform output -raw efs_file_system_id 2>/dev/null || \
  aws efs describe-file-systems --query 'FileSystems[?Tags[?Key==`Name`&&Value==`langfuse-prod-clickhouse-data`]].FileSystemId' --output text)

# 3. Start restore job — creates a NEW EFS file system with the recovered data
aws backup start-restore-job \
  --recovery-point-arn "<RECOVERY_POINT_ARN>" \
  --iam-role-arn "arn:aws:iam::<ACCOUNT_ID>:role/langfuse-prod-backup" \
  --metadata "{\"file-system-id\":\"$EFS_ID\",\"newFileSystem\":\"true\",\"CreationToken\":\"langfuse-restore-$(date +%s)\"}"
```

After restore:
1. Update the EFS mount target in Terraform to point to the restored file system, or
2. Copy the restored data back to the original EFS and restart the ClickHouse ECS service

**Retention period:** configured via `backup_retention_days` variable (default: 14 days).

---

### ClickHouse Native BACKUP (on-demand)

ClickHouse's built-in `BACKUP` command creates a consistent snapshot of both schema and data parts, stored directly in S3.

**Run a backup:**

```bash
# 1. Get cluster name, task ID, and ClickHouse S3 bucket from Terraform outputs
CLUSTER=$(terraform output -raw ecs_cluster_name)
CH_BUCKET=$(terraform output -raw s3_clickhouse_bucket_name)
REGION=ap-southeast-7   # เปลี่ยนตาม region ที่ deploy

TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name ${CLUSTER}-clickhouse \
  --region $REGION \
  --query 'taskArns[0]' --output text)

# 2. Run backup via ECS Exec
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ARN \
  --container clickhouse \
  --interactive \
  --region $REGION \
  --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \"BACKUP DATABASE langfuse \
    TO S3('https://$CH_BUCKET.s3.$REGION.amazonaws.com/native-backups/\$(date +%Y-%m-%d)/', '', '')\""
```

**Check backup status:**

```bash
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ARN \
  --container clickhouse \
  --interactive \
  --region $REGION \
  --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \"SELECT * FROM system.backups FORMAT Vertical\""
```

**Restore from ClickHouse native backup:**

```bash
# Stop web and worker first to prevent writes during restore
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 0 --region $REGION

# Restore (แทนที่ 2025-01-15 ด้วยวันที่ backup ที่ต้องการ)
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ARN \
  --container clickhouse \
  --interactive \
  --region $REGION \
  --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \"RESTORE DATABASE langfuse \
    FROM S3('https://$CH_BUCKET.s3.$REGION.amazonaws.com/native-backups/2025-01-15/', '', '')\""

# Restart services
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 1 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 1 --region $REGION
```

> ClickHouse native backup เก็บใน **ClickHouse S3 bucket** (`s3_clickhouse_bucket_name`) ใต้ prefix `native-backups/`  
> แยกจาก S3 data parts ที่อยู่ใต้ prefix `data/` ในถังเดียวกัน

---

## ClickHouse Keeper

### ทำไมถึงต้องใช้

Langfuse v3 สร้าง ClickHouse tables ด้วย `ReplicatedMergeTree` และ `ON CLUSTER` DDL เสมอ  
`ReplicatedMergeTree` ต้องการ coordination service (Keeper) **แม้จะเป็น single node** — ถ้าไม่มีจะ error ทันทีตอนรัน migration:

```
Coordination (Keeper) is not configured but ReplicatedMergeTree is used
```

การที่ config มี `<macros>` (`{cluster}`, `{shard}`, `{replica}`) ก็เพราะ Langfuse DDL ใช้ค่าเหล่านี้ใน `ON CLUSTER langfuse_cluster` statement

### สถาปัตยกรรม: Embedded Keeper

ClickHouse 22.4+ มี **Embedded Keeper** ที่รันในกระบวนการเดียวกับ ClickHouse server  
ไม่ต้องสร้าง ECS service แยก, ไม่มี security group เพิ่ม, ไม่มีค่าใช้จ่ายเพิ่ม

```
┌─────────────────────────────────────┐
│  ECS Fargate Task (ClickHouse)      │
│                                     │
│  ┌─────────────────────────────┐    │
│  │   clickhouse-server         │    │
│  │   port 8123 (HTTP)          │    │
│  │   port 9000 (native TCP)    │    │
│  │                             │    │
│  │   ┌─────────────────────┐   │    │
│  │   │  embedded keeper    │   │    │
│  │   │  port 9181 (client) │   │    │
│  │   │  port 9234 (Raft)   │   │    │
│  │   │  localhost only     │   │    │
│  │   └─────────────────────┘   │    │
│  └─────────────────────────────┘    │
│                                     │
│  EFS mount: /var/lib/clickhouse     │
│    ├── metadata/      (table DDL)   │
│    ├── disks/s3_disk/ (S3 pointers) │
│    └── coordination/  (Keeper data) │
└─────────────────────────────────────┘
```

Keeper data เก็บบน EFS (`/var/lib/clickhouse/coordination/`) จึงอยู่รอดได้เมื่อ container restart และถูก backup โดย AWS Backup อัตโนมัติพร้อมกับ metadata อื่น ๆ

### Config ที่ใช้งาน

Config ด้านล่างถูกฝังไว้ใน `modules/ecs_clickhouse/main.tf` แล้ว และถูก inject เข้า container อัตโนมัติตอน startup — ไม่ต้องแก้ไขอะไรเพิ่ม

```xml
<!-- 1. เปิด embedded Keeper -->
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

<!-- 2. บอก ClickHouse ให้ใช้ Keeper ที่ localhost -->
<zookeeper>
    <node>
        <host>localhost</host>
        <port>9181</port>
    </node>
</zookeeper>
```

### Ports ที่ใช้

| Port | Protocol | ใช้สำหรับ | เข้าถึงจาก |
|---|---|---|---|
| 8123 | HTTP | ClickHouse HTTP interface | Langfuse web/worker |
| 9000 | TCP | ClickHouse native protocol | Langfuse web/worker |
| 9181 | TCP | Keeper client (ZooKeeper-compatible) | localhost เท่านั้น |
| 9234 | TCP | Keeper Raft (leader election) | localhost เท่านั้น |

Port 9181 และ 9234 ใช้งานภายใน container เท่านั้น ไม่ต้องเพิ่ม security group rule

### ตรวจสอบสถานะ Keeper

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER --family langfuse-prod-clickhouse \
  --query 'taskArns[0]' --output text | awk -F/ '{print $NF}')

# เช็คว่า Keeper พร้อมใช้งาน
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ID \
  --container clickhouse \
  --interactive \
  --command "clickhouse-keeper-client -h localhost -p 9181 --query 'ruok'"
# ตอบ: imok

# เช็ค Keeper stats
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ID \
  --container clickhouse \
  --interactive \
  --command "clickhouse-keeper-client -h localhost -p 9181 --query 'stat'"
```

---

## Troubleshooting

### ClickHouse container exits with code 76

**อาการ:** ECS task หยุดด้วย exit code 76 และ log แสดง:
```
DB::Exception: Cannot lock file /var/lib/clickhouse/status.
Another server instance in same directory is already running.
```

**สาเหตุ:** ClickHouse ล้มเหลวไม่สะอาด (crash หรือถูก SIGKILL) ทำให้ไฟล์ lock `/var/lib/clickhouse/status` ค้างบน EFS container ใหม่เปิดขึ้นมาแล้วพบไฟล์นี้และ lock ไม่ได้

**วิธีแก้ที่ใช้ใน Terraform นี้:** startup command ของ container ลบไฟล์นี้ก่อนเสมอ:
```sh
rm -f /var/lib/clickhouse/status && exec /entrypoint.sh
```
หาก container ยังค้างอยู่และไม่ยอมหาย ให้ force-stop task เก่าก่อน:
```bash
aws ecs update-service --cluster <cluster> --service <svc>-clickhouse --force-new-deployment
```

---

### ClickHouse logs ไม่ขึ้นใน CloudWatch

**อาการ:** log stream มีอยู่แต่ `storedBytes = 0`

**สาเหตุ:** ClickHouse เขียน log ลงไฟล์ (`/var/log/clickhouse-server/`) โดย default ไม่ส่งออก stdout

**วิธีแก้ที่ใช้:** config XML ใน `modules/ecs_clickhouse/main.tf` มี `<logger><console>1</console></logger>` อยู่แล้ว ทำให้ทุก log ถูกส่งออก stdout → CloudWatch โดยอัตโนมัติ

---

### Terraform ล้มเหลวด้วย `x509: certificate signed by unknown authority` (Windows)

**อาการ:** `terraform apply` หรือ `terraform plan` ล้มเหลวทันทีพร้อม TLS error

**สาเหตุ:** Antivirus บางตัว (เช่น Norton) ดักจับ TLS ของ connection gRPC ระหว่าง Terraform core กับ provider plugin ที่รันบน localhost

**วิธีแก้:** ใช้ WSL2 แทน:
```bash
wsl -d Ubuntu-20.04 -- bash -c "cd /mnt/d/path/to/langfuse_terraform && terraform apply"
```

---

### RDS CloudWatch Log Group ถูกสร้างอัตโนมัติทำให้ `terraform apply` ล้มเหลว

**อาการ:**
```
Error: creating CloudWatch Logs Log Group (/aws/rds/cluster/<prefix>-db/postgresql):
ResourceAlreadyExistsException: The specified log group already exists
```

**สาเหตุ:** Aurora สร้าง log group `/aws/rds/cluster/<prefix>-db/postgresql` อัตโนมัติเมื่อ cluster เริ่มเขียน log ก่อนที่ Terraform จะสร้าง resource นั้น

**วิธีแก้:** Import log group เข้า Terraform state แล้ว apply ต่อ:
```bash
terraform import module.database.aws_cloudwatch_log_group.rds /aws/rds/cluster/<prefix>-db/postgresql
terraform apply -auto-approve
```

---

### ECS service ค้างอยู่ที่ rev เก่า หลังจาก `terraform apply`

ClickHouse service มี `lifecycle { ignore_changes = [task_definition] }` เพื่อกันไม่ให้ Terraform rollback task ที่ deploy ด้วยมือ  
เมื่อ `terraform apply` สร้าง task definition ใหม่แต่ service ยังใช้ revision เดิม ให้ force-redeploy:

```bash
aws ecs update-service \
  --cluster <cluster-name> \
  --service <prefix>-clickhouse \
  --task-definition <prefix>-clickhouse \
  --force-new-deployment
```

---

## Cost Estimate (us-east-1, default config)

Exchange rate used: **1 USD = 33.5 THB** (approximate, verify before budgeting).

### Daily cost breakdown

| Service | Resource | Unit price | Daily usage | Daily cost (USD) |
|---|---|---|---|---|
| **Aurora PostgreSQL** | db.r6g.large writer | $0.26/hr | 24 hr | $6.24 |
| **Aurora PostgreSQL** | db.r6g.large reader | $0.26/hr | 24 hr | $6.24 |
| **ElastiCache Valkey** | cache.t3.small | $0.034/hr | 24 hr | $0.82 |
| **ECS Fargate** | Web (2 vCPU / 4 GB × 1 task) | $0.04048/vCPU-hr + $0.004445/GB-hr | 24 hr | $2.37 |
| **ECS Fargate** | Worker (2 vCPU / 4 GB × 1 task) | same | 24 hr | $2.37 |
| **ECS Fargate** | ClickHouse (1 vCPU / 8 GB × 1 task) | same | 24 hr | $1.88 |
| **ALB** | Fixed + LCU | $0.008/hr + usage | 24 hr | ~$0.19 |
| **NAT Gateway** | 1 AZ × $0.045/hr (default) | per hour | 24 hr | $1.08 |
| **EFS** | generalPurpose ~1 GB stored | $0.30/GB-mo | 1 mo avg | ~$0.01 |
| **S3** | Blob + Events + ClickHouse data | ~$0.023/GB-mo | minimal | ~$0.05 |
| **AWS Backup** | EFS recovery points ~1 GB/day | $0.05/GB-mo | 14 days | ~$0.02 |
| **Secrets Manager** | 3 secrets | $0.40/secret/mo | — | $0.04 |
| **CloudWatch Logs** | Web + Worker + ClickHouse + RDS | $0.50/GB ingested | minimal | ~$0.05 |

### Summary

| | USD/day | THB/day |
|---|---|---|
| **ต่ำสุด** (traffic น้อย, S3/data minimal, 1 NAT GW) | **~$19.00** | **~637 บาท** |
| **ปกติ** (รวม data transfer + S3 growth) | **~$21–23** | **~700–770 บาท** |
| **เดือนละ (ปกติ)** | **~$630–700** | **~21,000–23,500 บาท** |

> ใช้ `nat_gateway_count = 3` เพื่อ full AZ redundancy จะเพิ่มค่าใช้จ่าย ~$2.16/วัน ($3.24 - $1.08)

### จุดที่กินค่าใช้จ่ายมากที่สุด

1. **Aurora PostgreSQL** (~$12.48/วัน, 65%) — สองอินสแตนซ์ db.r6g.large วิ่งตลอด 24 ชั่วโมง  
   ลดได้โดยเปลี่ยนเป็น `db.t4g.medium` หากใช้งาน dev/staging
2. **ECS Fargate** (~$6.62/วัน รวม 3 services, 35%) — ราคาตามขนาด task ที่กำหนด
3. **NAT Gateway** (~$1.08/วัน default 1 GW) — จำเป็นสำหรับ private subnets ดึง container images

### ปรับลดค่าใช้จ่ายสำหรับ non-production

```hcl
# terraform.tfvars
db_instance_class = "db.t4g.medium"   # ประหยัดได้ ~$9/วัน
cache_node_type   = "cache.t3.micro"  # ประหยัดได้ ~$0.40/วัน
web_max_capacity  = 1                 # ปิด auto-scale
nat_gateway_count = 1                 # default แล้ว
```

---

## Module Structure

```
modules/
├── networking/        # VPC, subnets, IGW, NAT GW (1–3), route tables, S3 endpoint
├── security_groups/   # SGs for ALB, web, worker, ClickHouse, RDS, Redis, EFS
├── iam/               # Task execution role + 3 task roles (web, worker, clickhouse)
├── secrets/           # Secrets Manager (db, clickhouse, app) + random passwords
├── storage/           # S3 x3, ECR x3, EFS + mount targets + access point
├── database/          # Aurora PostgreSQL 15.4 (writer + reader)
├── cache/             # ElastiCache Valkey 7.2
├── service_discovery/ # Cloud Map namespace langfuse.local
├── load_balancer/     # ALB, HTTP listener, target group
├── ecs_cluster/       # ECS cluster + CloudWatch log groups
├── ecs_clickhouse/    # ClickHouse task + service + S3 config injection
├── ecs_langfuse_web/  # Web task + service + ALB + auto-scaling
├── ecs_langfuse_worker/ # Worker task + service
└── backup/            # AWS Backup vault + plan + EFS selection
```
