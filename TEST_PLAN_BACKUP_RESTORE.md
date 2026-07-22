# Test Plan — Backup & Restore (Langfuse / ClickHouse / PostgreSQL)

เอกสารนี้กำหนด **test case** สำหรับตรวจสอบว่ากลไก backup และ restore ของระบบ Langfuse บน Terraform นี้ทำงานได้จริง ครอบคลุมทั้ง ClickHouse (EFS metadata + native S3 backup) และ PostgreSQL/Aurora

สำหรับ *วิธีรัน* คำสั่ง backup/restore แบบละเอียด อ้างอิง [README.md](./README.md) หัวข้อ `Backup and Recovery` และ `Destroy` เป็น source of truth — เอกสารนี้กำหนดว่า **ต้องตรวจอะไรบ้าง** และ **ผลลัพธ์ที่คาดหวังคืออะไร**

---

## 1. Scope and Purpose

**ใครควรใช้เอกสารนี้:** ผู้ดูแลระบบ (operator) ที่ต้อง verify backup/restore ก่อน production migration, ตาม DR drill รายไตรมาส, หรือก่อน `terraform destroy`

**เมื่อไหร่ควรรัน:**
- หลัง deploy ครั้งแรก (baseline verification)
- ก่อน schema migration ที่มีความเสี่ยงสูง
- DR drill ตามรอบ (แนะนำ: รายไตรมาส)
- ก่อน `terraform destroy` ถ้าต้องการเก็บ recovery points ไว้

**สิ่งที่ทดสอบ:** สอง data layer ที่มีความเสี่ยงสูงตาม Layered Backup Strategy ใน README.md — ClickHouse EFS metadata (AWS Backup) และ ClickHouse data (native BACKUP/RESTORE ผ่าน S3) รวมถึง PostgreSQL/Aurora ในระดับ configuration verification

---

## 2. Test Environment & Preconditions

ก่อนเริ่ม test case ใด ๆ ต้องมี:

| Requirement | รายละเอียด |
|---|---|
| Terraform applied | Infra deploy สำเร็จแล้ว, `terraform output` ใช้งานได้ |
| AWS CLI access | สิทธิ์ `backup:*`, `ecs:ExecuteCommand`, `ecs:DescribeServices`, `efs:*`, `rds:Describe*` |
| ECS Exec enabled | `enableExecuteCommand = true` บน ClickHouse service (ดู TC-PRE-01) |
| Environment ที่ไม่ใช่ production | Test ที่มีคำเตือน `> ⚠` (destructive) **ห้ามรันกับ production** |
| Terraform outputs ที่ต้องใช้ | `ecs_cluster_name`, `s3_clickhouse_bucket_name` (ดู Appendix สำหรับ setup แบบเต็ม) |

---

## 3. Out of Scope

ต่อไปนี้ **ไม่อยู่ในขอบเขต** ของ test plan นี้ เพราะสถาปัตยกรรมปัจจุบันไม่รองรับ ไม่ใช่แค่ "ยังไม่ได้ทดสอบ":

- **Multi-shard / multi-replica ClickHouse failover** — `modules/ecs_clickhouse/main.tf` กำหนด cluster แบบ 1 shard / 1 replica เท่านั้น (`internal_replication = false`), ECS `desired_count = 1`, และ embedded Keeper มี `<server id=1>` เพียงตัวเดียว ไม่มี code path ใดในระบบนี้ที่สร้าง ClickHouse node ที่สอง — หากเพิ่ม multi-node ในอนาคต ควรกลับมาทบทวนหัวข้อนี้ใหม่
- **Keeper multi-node quorum / leader election testing** — เหตุผลเดียวกัน (single embedded Keeper)
- **Cross-region Disaster Recovery** — ไม่มี cross-region replication หรือ secondary-region infrastructure ใน Terraform config นี้

---

## 4. Known Issues Affecting Test Execution

> **✅ แก้ไขแล้ว (resolved):** README.md หัวข้อ `ClickHouse Keeper` (บรรทัด ~420) เคยเขียนว่า macros ถูกใช้ใน `ON CLUSTER langfuse_cluster` statement ซึ่งไม่ตรงกับ config จริงหลัง commit `9acf3e3` ที่เปลี่ยนชื่อ cluster เป็น `default` (เพราะ Langfuse migrations ใช้ `ON CLUSTER default` เสมอ — ชื่อ cluster ที่ไม่ตรงกันเคยทำให้ table ถูกสร้างผิด database) ข้อความใน README.md ได้รับการอัปเดตให้ตรงกับ `default` แล้ว
>
> TC-CLUSTER-01/02 ด้านล่างยังคงมีไว้เป็น **regression check** — เพื่อยืนยันว่าชื่อ cluster ไม่ถูกเปลี่ยนกลับไปเป็น `langfuse_cluster` โดยไม่ตั้งใจในอนาคต ไม่ใช่เพราะยังมี doc/code mismatch อยู่

---

## 5. Test Case Format

แต่ละ subsection ใน §6 เริ่มด้วยตาราง summary (`Test ID | Scenario | Priority | Destructive?`) ตามด้วยรายละเอียดแต่ละ test case ในรูปแบบ **Preconditions / Steps / Expected Result** — คำสั่งที่ยาวหรือ multi-line (bash, SQL, JSON) จะไม่ถูกใส่ในตาราง เพราะอ่านยากและ escape ยุ่งยาก เช่นเดียวกับที่ README.md เองก็ไม่เคยใส่ command ยาวในตาราง

Test case ที่มีคำเตือน `> ⚠` หมายถึง **destructive** — ต้องรันในสภาพแวดล้อมที่ไม่ใช่ production เท่านั้น

---

## 6. Test Cases

### 6.1 Pre-flight / Environment Checks

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-PRE-01 | ECS Exec enabled บน ClickHouse service | High | No |
| TC-PRE-02 | Terraform outputs resolvable | High | No |
| TC-PRE-03 | ECS service ไม่ค้างอยู่ที่ task-def revision เก่า | Medium | No |

**TC-PRE-01 — ECS Exec enabled**
- **Preconditions:** Terraform applied, ClickHouse service กำลังรันอยู่
- **Steps:**
  ```bash
  CLUSTER=$(terraform output -raw ecs_cluster_name)
  REGION=ap-southeast-7
  aws ecs describe-services \
    --cluster $CLUSTER \
    --services ${CLUSTER}-clickhouse \
    --region $REGION \
    --query 'services[0].enableExecuteCommand'
  ```
- **Expected Result:** คืนค่า `true` — หากเป็น `false` ทุก test case ใน §6.3 (TC-CHBK-*) จะ fail ที่ขั้นตอน exec เพราะพึ่งพา ECS Exec

**TC-PRE-02 — Terraform outputs resolvable**
- **Preconditions:** อยู่ใน working directory ที่มี Terraform state
- **Steps:**
  ```bash
  terraform output -raw ecs_cluster_name
  terraform output -raw s3_clickhouse_bucket_name
  ```
- **Expected Result:** ทั้งสองคำสั่งคืนค่าไม่ว่างเปล่า — เก็บไว้เป็น `$CLUSTER` / `$CH_BUCKET` สำหรับ test case ถัดไป

**TC-PRE-03 — Fresh task definition ถูก deploy จริง**
- **Preconditions:** เพิ่งรัน `terraform apply` มาไม่นาน
- **Rationale:** README.md (~บรรทัด 589) บันทึกไว้ว่า ClickHouse service มี `lifecycle.ignore_changes = [task_definition]` ทำให้ service อาจค้างอยู่ที่ revision เก่าแม้ apply สำเร็จ
- **Steps:**
  ```bash
  REGION=ap-southeast-7
  aws ecs describe-task-definition \
    --task-definition ${CLUSTER}-clickhouse \
    --region $REGION \
    --query 'taskDefinition.revision'

  aws ecs describe-services \
    --cluster $CLUSTER --services ${CLUSTER}-clickhouse \
    --region $REGION \
    --query 'services[0].taskDefinition'
  ```
- **Expected Result:** revision ที่ service ใช้งานตรงกับ revision ล่าสุดที่ register ไว้ — ยืนยันว่า test ถัดไปทดสอบกับ config ปัจจุบัน ไม่ใช่ image เก่า

---

### 6.2 AWS Backup — EFS Metadata Backup & Restore

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-EFS-01 | Backup plan มีอยู่จริงและตั้ง schedule ถูกต้อง | High | No |
| TC-EFS-02 | Recovery point ถูกสร้างตาม schedule | High | No |
| TC-EFS-03 | สร้าง recovery point แบบ on-demand | Medium | No |
| TC-EFS-04 | Restore EFS แบบเต็ม (DR drill) | High | ⚠ Yes |

**TC-EFS-01 — Backup plan และ schedule ถูกต้อง**
- **Steps:**
  ```bash
  aws backup list-backup-plans --region ap-southeast-7
  ```
- **Expected Result:** พบ plan ชื่อ `<name_prefix>-efs-daily` มี rule schedule `cron(0 2 * * ? *)` และ `delete_after` ตรงกับค่า `backup_retention_days` ใน `terraform.tfvars` (default 14 วัน)

**TC-EFS-02 — Recovery point ล่าสุดสำเร็จ**
- **Steps:**
  ```bash
  aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name <name_prefix>-vault \
    --region ap-southeast-7 \
    --query 'RecoveryPoints[*].{Date:CreationDate,Status:Status,ARN:RecoveryPointArn}' \
    --output table
  ```
- **Expected Result:** มี recovery point อย่างน้อย 1 รายการ สถานะ `COMPLETED` และวันที่ล่าสุดอยู่ภายใน 24–48 ชั่วโมงที่ผ่านมา (ตาม cron 02:00 UTC ทุกวัน)

**TC-EFS-03 — สร้าง on-demand recovery point**
- **Rationale:** ใช้แทนการรอ cron รอบถัดไป เพื่อให้ TC-EFS-04 มี recovery point ล่าสุดให้ restore ทันที
- **Steps:**
  ```bash
  aws backup start-backup-job \
    --resource-arn <EFS_ARN> \
    --iam-role-arn arn:aws:iam::<ACCOUNT_ID>:role/<name_prefix>-backup \
    --backup-vault-name <name_prefix>-vault \
    --region ap-southeast-7
  ```
- **Expected Result:** job เปลี่ยนสถานะเป็น `COMPLETED` ภายใน completion window (180 นาที ตามที่กำหนดใน `modules/backup/main.tf`)

**TC-EFS-04 — Restore EFS แบบเต็ม (สร้าง filesystem ใหม่)**
- > **⚠ Destructive/resource-creating:** สร้าง EFS filesystem ใหม่จริงบน AWS — รันเฉพาะใน environment ที่ยอมรับค่าใช้จ่ายเพิ่มเติมและ cleanup ได้
- **Preconditions:** มี recovery point พร้อมใช้ (จาก TC-EFS-02 หรือ TC-EFS-03)
- **Steps** (อ้างอิง README.md บรรทัด 314–328):
  ```bash
  EFS_ID=$(terraform output -raw efs_file_system_id 2>/dev/null || \
    aws efs describe-file-systems \
      --region ap-southeast-7 \
      --query 'FileSystems[?Tags[?Key==`Name`&&Value==`langfuse-prod-clickhouse-data`]].FileSystemId' \
      --output text)

  aws backup start-restore-job \
    --recovery-point-arn "<RECOVERY_POINT_ARN>" \
    --iam-role-arn "arn:aws:iam::<ACCOUNT_ID>:role/langfuse-prod-backup" \
    --metadata "{\"file-system-id\":\"$EFS_ID\",\"newFileSystem\":\"true\",\"CreationToken\":\"langfuse-restore-$(date +%s)\"}" \
    --region ap-southeast-7

  # Poll สถานะ
  aws backup describe-restore-job --restore-job-id <RESTORE_JOB_ID> --region ap-southeast-7
  ```
- **Expected Result:** restore job สถานะ `COMPLETED`; EFS filesystem ใหม่มี `/var/lib/clickhouse/metadata/`, `/disks/s3_disk/`, `/coordination/` ครบถ้วน
- **หมายเหตุ:** test นี้ **ไม่รวม** ขั้นตอน repoint ECS mount ไปยัง filesystem ใหม่ — เป็นขั้นตอน manual แยกต่างหากตามที่ README.md ระบุ (อัปเดต Terraform mount target หรือ copy ข้อมูลกลับไปที่ EFS เดิมแล้ว restart service)

---

### 6.3 ClickHouse Native BACKUP / RESTORE (S3)

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-CHBK-01 | รัน `BACKUP DATABASE` สำเร็จ | High | No |
| TC-CHBK-02 | ตรวจสอบสถานะผ่าน `system.backups` | High | No |
| TC-CHBK-03 | Restore แบบเต็ม พร้อม verify row count | High | ⚠ Yes |
| TC-CHBK-04 | ยืนยันข้อจำกัด whole-database-only | Low | No |

**TC-CHBK-01 — รัน BACKUP DATABASE**
- **Preconditions:** TC-PRE-01, TC-PRE-02 ผ่านแล้ว
- **Steps** (อ้างอิง README.md บรรทัด 345–366 — หมายเหตุ: argument `'', ''` ว่างเปล่าตั้งใจให้ ClickHouse ใช้ ECS task IAM role แทน credential ตรง ๆ ตาม commit `875766c`):
  ```bash
  CLUSTER=$(terraform output -raw ecs_cluster_name)
  CH_BUCKET=$(terraform output -raw s3_clickhouse_bucket_name)
  REGION=ap-southeast-7

  TASK_ARN=$(aws ecs list-tasks \
    --cluster $CLUSTER \
    --service-name ${CLUSTER}-clickhouse \
    --region $REGION \
    --query 'taskArns[0]' --output text)

  aws ecs execute-command \
    --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
    --interactive --region $REGION \
    --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
      --query \"BACKUP DATABASE langfuse_system \
      TO S3('https://$CH_BUCKET.s3.$REGION.amazonaws.com/native-backups/\$(date +%Y-%m-%d)/', '', '')\""
  ```
- **Expected Result:** คำสั่งจบโดยไม่มี error; ปรากฏ prefix ใหม่ `native-backups/<วันที่วันนี้>/` ใน `$CH_BUCKET` (ตรวจด้วย `aws s3 ls s3://$CH_BUCKET/native-backups/`)

**TC-CHBK-02 — ตรวจสอบผ่าน system.backups**
- **Steps:**
  ```bash
  aws ecs execute-command \
    --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
    --interactive --region $REGION \
    --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
      --query \"SELECT * FROM system.backups FORMAT Vertical\""
  ```
- **Expected Result:** พบแถวที่มี `status = BACKUP_CREATED` ตรงกับ path/ชื่อ backup จาก TC-CHBK-01

**TC-CHBK-03 — Restore แบบเต็ม**
- > **⚠ Destructive:** ทับข้อมูลปัจจุบันใน database `langfuse_system` — รันเฉพาะ environment ที่ยอมรับการสูญเสียข้อมูลได้
- **Preconditions:** มี backup ที่สำเร็จแล้ว (TC-CHBK-01); บันทึก row count ของตารางสำคัญ (เช่น `traces`, `observations`) ไว้เป็น baseline **ก่อน** restore
- **Steps** (อ้างอิง README.md บรรทัด 384–402):
  ```bash
  aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 0 --region $REGION
  aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 0 --region $REGION

  aws ecs execute-command \
    --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
    --interactive --region $REGION \
    --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
      --query \"RESTORE DATABASE langfuse_system \
      FROM S3('https://$CH_BUCKET.s3.$REGION.amazonaws.com/native-backups/<YYYY-MM-DD>/', '', '')\""

  aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 1 --region $REGION
  aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 1 --region $REGION
  ```
- **Expected Result:** restore สำเร็จ; row count ของตารางสำคัญตรงกับ baseline ก่อน backup; web/worker service กลับมา `RUNNING`/healthy หลัง restart

**TC-CHBK-04 — ยืนยันข้อจำกัด whole-database-only**
- **Rationale:** native BACKUP/RESTORE ในระบบนี้ทำงานระดับ database (`BACKUP DATABASE langfuse_system`) เท่านั้น ไม่มีตัวอย่างการ restore เฉพาะ table ที่ผ่านการทดสอบ
- **Steps:** ลองรัน `RESTORE TABLE langfuse_system.traces FROM S3(...)` กับ backup ที่ backup ทั้ง database ไว้
- **Expected Result:** บันทึกพฤติกรรมจริงที่เกิดขึ้น (restore สำเร็จบางส่วน, ต้อง restore ทั้ง database, หรือ ClickHouse คืน error ชัดเจน) — วัตถุประสงค์ของ test นี้คือยืนยันพฤติกรรมจริง ไม่ใช่สมมติไว้ล่วงหน้า

---

### 6.4 PostgreSQL / Aurora Backup & Restore Verification

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-PG-01 | Automated backup configuration ถูกต้อง | Medium | No |
| TC-PG-02 | Point-in-time restore (PITR) drill | Low | No (สร้าง cluster ใหม่แยกต่างหาก) |
| TC-PG-03 | Snapshot listing sanity check | Medium | No |

> Aurora มี automated backup + PITR ในตัว ความเสี่ยงจัดเป็น "ต่ำ" ตาม Layered Backup Strategy ใน README.md ดังนั้น test group นี้เน้น verify configuration มากกว่า full DR drill

**TC-PG-01 — Configuration verification**
- **Steps:**
  ```bash
  aws rds describe-db-clusters \
    --db-cluster-identifier <cluster-id> \
    --region ap-southeast-7 \
    --query 'DBClusters[0].{Retention:BackupRetentionPeriod,Window:PreferredBackupWindow}'
  ```
- **Expected Result:** `Retention` ตรงกับ `var.db_backup_retention` (default 3 วัน), `Window` = `03:00-04:00` ตามที่กำหนดใน `modules/database/main.tf`

**TC-PG-02 — PITR restore drill (optional/low priority)**
- **Steps:**
  ```bash
  aws rds restore-db-cluster-to-point-in-time \
    --source-db-cluster-identifier <cluster-id> \
    --db-cluster-identifier <cluster-id>-pitr-test \
    --restore-to-time <ISO8601-timestamp> \
    --region ap-southeast-7
  ```
- **Expected Result:** cluster ใหม่ (`<cluster-id>-pitr-test`) ถึงสถานะ `available`; สุ่มตรวจข้อมูลว่าตรงกับสถานะ ณ เวลาที่ restore-to
- **หมายเหตุ:** สร้าง cluster ใหม่แยกต่างหาก ไม่กระทบ cluster เดิม — priority ต่ำ ไม่จำเป็นต้องรันทุก release cycle

**TC-PG-03 — Snapshot listing sanity check**
- **Steps:**
  ```bash
  aws rds describe-db-cluster-snapshots \
    --db-cluster-identifier <cluster-id> \
    --region ap-southeast-7 \
    --query 'DBClusterSnapshots[*].{ID:DBClusterSnapshotIdentifier,Type:SnapshotType,Status:Status}'
  ```
- **Expected Result:** พบ automated snapshot สถานะ `available` สอดคล้องกับ retention 3 วัน

---

### 6.5 Cluster Name / ON CLUSTER DDL Regression Check

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-CLUSTER-01 | Cluster name เป็น `default` | High | No |
| TC-CLUSTER-02 | Migration ลง table ถูก database/cluster | High | No |

> ดู §4 Known Issues — README.md เคยมีข้อความอ้างอิงชื่อ cluster เก่า (`langfuse_cluster`) ที่ล้าสมัย แต่ได้แก้ไขแล้ว; test group นี้ยังคงไว้เป็น regression check

**TC-CLUSTER-01 — Cluster name ต้องเป็น `default`**
- **Rationale:** commit `9acf3e3` เปลี่ยนชื่อ cluster จาก `langfuse_cluster` เป็น `default` เพราะ Langfuse migrations ใช้ `ON CLUSTER default` เสมอ การไม่ตรงกันเคยทำให้ table ถูกสร้างผิด database — test นี้ป้องกัน regression ของ config นี้
- **Steps:**
  ```bash
  aws ecs execute-command \
    --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
    --interactive --region $REGION \
    --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
      --query \"SELECT cluster, shard_num, replica_num FROM system.clusters WHERE cluster = 'default' FORMAT Vertical\""
  ```
- **Expected Result:** พบ 1 แถว, `cluster = default`, `shard_num = 1`, `replica_num = 1`

**TC-CLUSTER-02 — Migration ลง table ถูก database**
- **Preconditions:** เพิ่ง redeploy web service เพื่อให้ migration รันใหม่ (หรือหลัง TC-CHBK-03 restore)
- **Steps:**
  ```sql
  SELECT database, name, engine FROM system.tables WHERE database = 'langfuse_system' FORMAT Vertical
  ```
- **Expected Result:** ตารางหลักของ Langfuse (`traces`, `observations`, `scores` ฯลฯ) มีอยู่ใน database `langfuse_system` ด้วย engine `ReplicatedMergeTree` — ยืนยันว่า `ON CLUSTER default` DDL ลงถูก cluster/database จริง

---

### 6.6 Negative / Failure-Mode Scenarios (จาก incident history)

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-NEG-01 | EFS lock conflict ตอน redeploy (exit code 210) | Medium | ⚠ Yes |
| TC-NEG-02 | Stale-lock cleanup ไม่บดบัง concurrent conflict จริง | Medium | ⚠ Yes |
| TC-NEG-03 | Concurrent writer ทำ system table เสีย (regression check) | Medium | No (post-check) |
| TC-NEG-04 | Unclean restart / exit code 76 | Medium | ⚠ Yes |

**TC-NEG-01 — EFS lock conflict ตอน redeploy**
- > **⚠** รันเฉพาะ non-production — บังคับ redeploy ระหว่าง task เก่ายังไม่ drain เสร็จ
- **Steps:**
  ```bash
  aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-clickhouse --force-new-deployment --region ap-southeast-7
  ```
  สังเกตสถานะ task ระหว่างการเปลี่ยนผ่าน
- **Expected Result:** task ใหม่ไม่ crash ด้วย exit code 210 เพราะ `deployment_maximum_percent = 100` บังคับ stop-before-start อยู่แล้ว หากยัง fail ให้ยืนยันว่า manual fix ที่ backันไว้ใช้ได้: `aws ecs stop-task --task <old-arn> --region ap-southeast-7`

**TC-NEG-02 — Stale-lock cleanup ไม่บดบัง concurrent conflict จริง**
- > **⚠** ต้อง scale service ชั่วคราวเป็น 2 tasks — ทำใน environment ทดสอบเท่านั้น เพราะเสี่ยงข้อมูลเสีย (ดู incident #8 ด้านล่าง)
- **Rationale:** startup command รัน `rm -f /var/lib/clickhouse/status && exec /entrypoint.sh` เสมอ ต้องยืนยันว่าไม่ได้บดบัง scenario ที่มี 2 instance รันจริงพร้อมกัน
- **Steps:** scale `desired_count` เป็น 2 ชั่วคราว (หรือ start task ที่สองชี้ EFS เดียวกัน) สังเกตว่า ClickHouse ตรวจพบ conflict ระดับ EFS lock จริงหรือไม่
- **Expected Result:** instance ที่สองต้อง fail ชัดเจน (ไม่ silent dual-write) — หากทั้งสอง instance "สำเร็จ" พร้อมกัน ถือว่า **fail** และต้อง escalate ทันที (นี่คือ failure mode เดียวกับ incident #8: `CANNOT_READ_ALL_DATA` จาก concurrent writer)

**TC-NEG-03 — Concurrent writer ทำ system table เสีย (regression check)**
- **Rationale:** incident ที่เคยเกิด — สอง ClickHouse task เขียน S3 part ขัดแย้งกันทำให้ system table เสียหาย
- **Steps:** หลังรัน redeploy/restore test ใด ๆ ในเอกสารนี้ ให้ตรวจ:
  ```sql
  SELECT count() FROM system.text_log;
  SELECT count() FROM system.part_log;
  ```
  และตรวจ CloudWatch logs หา `CANNOT_READ_ALL_DATA`
- **Expected Result:** ไม่พบ `CANNOT_READ_ALL_DATA` ใน log; query ด้านบนสำเร็จ — หาก fail ให้ใช้ทางแก้ที่บันทึกไว้ (`terraform destroy && terraform apply`) เป็นทางเลือกสุดท้ายเท่านั้น (มีความเสี่ยงข้อมูลสูญหาย ต้องแจ้งเตือนก่อนทำ)

**TC-NEG-04 — Unclean restart / exit code 76**
- > **⚠** จำลอง unclean shutdown — ทำใน non-production
- **Steps:** `aws ecs stop-task --cluster $CLUSTER --task <task-arn> --region ap-southeast-7` แบบไม่ผ่าน graceful drain แล้วสังเกต task ถัดไป
- **Expected Result:** task ใหม่ start สำเร็จเพราะ startup command ลบ `/var/lib/clickhouse/status` ก่อนเสมอ; ไม่พบ exit code 76 ใน stopped reason

---

### 6.7 Destroy-Time Backup Vault Cleanup

| Test ID | Scenario | Priority | Destructive? |
|---|---|---|---|
| TC-DESTROY-01 | Destroy fail เมื่อ vault มี recovery point (expected failure) | High | ⚠ Yes |
| TC-DESTROY-02 | Detach-then-destroy เก็บ snapshot ไว้ได้ | High | ⚠ Yes |
| TC-DESTROY-03 | Manual cleanup ของ orphaned vault | Medium | ⚠ Yes |

**TC-DESTROY-01 — Destroy ต้อง fail เมื่อ vault ไม่ว่าง (expected-failure test)**
- > **⚠** รันเฉพาะ environment ที่ตั้งใจจะ destroy จริง
- **Preconditions:** มี recovery point อยู่ (จาก TC-EFS-02/03)
- **Steps:**
  ```bash
  terraform destroy
  ```
- **Expected Result:** destroy **fail** ด้วย error `Non-empty backup vault` — พฤติกรรมนี้ถูกต้องตามที่ตั้งใจ (README.md บรรทัด ~231) test นี้ยืนยันว่า error เกิดขึ้นจริง ไม่ใช่ยืนยันว่า destroy สำเร็จ

**TC-DESTROY-02 — Detach vault แล้ว destroy เก็บ snapshot ไว้ได้**
- **Steps** (README.md บรรทัด 236–244):
  ```bash
  terraform state rm module.backup.aws_backup_vault.langfuse
  terraform state rm module.backup.aws_backup_plan.efs
  terraform state rm module.backup.aws_backup_selection.efs
  terraform destroy
  ```
- **Expected Result:** destroy สำเร็จ; vault และ recovery point ยังอยู่ใน AWS หลัง destroy (ตรวจด้วย `aws backup list-backup-vaults`)

**TC-DESTROY-03 — Manual cleanup ของ vault ที่เหลืออยู่**
- **Preconditions:** ทำหลัง TC-DESTROY-02 เมื่อไม่ต้องการ snapshot แล้วเท่านั้น
- **Steps** (README.md บรรทัด 248–256):
  ```bash
  aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name <prefix>-vault --region ap-southeast-7 \
    --query 'RecoveryPoints[].RecoveryPointArn' --output text | \
    tr '\t' '\n' | xargs -I{} aws backup delete-recovery-point \
    --backup-vault-name <prefix>-vault --recovery-point-arn {} --region ap-southeast-7

  aws backup delete-backup-vault --backup-vault-name <prefix>-vault --region ap-southeast-7
  ```
- **Expected Result:** vault ไม่ปรากฏใน `aws backup list-backup-vaults` อีกต่อไป

---

## 7. Test Execution Log Template

| Date | Tester | Environment | Test IDs Run | Pass/Fail | Notes |
|---|---|---|---|---|---|
| | | | | | |

---

## 8. Appendix — Command Reference Cheat Sheet

ตัวแปร environment ที่ใช้ซ้ำในหลาย test case — ตั้งค่าครั้งเดียวก่อนเริ่ม:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
CH_BUCKET=$(terraform output -raw s3_clickhouse_bucket_name)
REGION=ap-southeast-7

TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name ${CLUSTER}-clickhouse \
  --region $REGION \
  --query 'taskArns[0]' --output text)
```

ตัวแปรเหล่านี้ถูกใช้ซ้ำในเกือบทุก test case ใน §6.2–6.6 — อ้างอิงกลับมาที่นี่แทนการเขียนซ้ำทุกครั้ง
