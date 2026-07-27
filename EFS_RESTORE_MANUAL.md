# EFS Restore Manual — AWS Backup → ClickHouse → Terraform State

เอกสารนี้เป็น manual ครบวงจรสำหรับ restore ClickHouse EFS จาก AWS Backup recovery point ไปจนถึงทำให้ Terraform เป็น source of truth ของ infra ใหม่แบบถาวร (ไม่ทิ้ง drift ไว้) — เขียนขึ้นจากขั้นตอนจริงที่ทำและ debug มาแล้วครบ รวมทุกจุดที่พลาดง่าย

**เมื่อไหร่ต้องใช้:** DR drill, กู้ข้อมูลจริงหลังเหตุการณ์ข้อมูลเสีย/หาย, หรือทดสอบ backup/restore ตาม [TEST_PLAN_BACKUP_RESTORE.md](./TEST_PLAN_BACKUP_RESTORE.md) TC-EFS-04

**ภาพรวมขั้นตอนทั้งหมด:**
1. Trigger AWS Backup restore job → ได้ EFS filesystem ใหม่
2. Repoint ClickHouse ECS ไปยัง filesystem ใหม่ (ชั่วคราว ผ่าน AWS CLI ตรงๆ)
3. Verify ข้อมูล
4. **Reconcile ถาวร** — ทำให้ path ข้อมูลสะอาด, import เข้า Terraform state, ย้าย IAM เป็นถาวร, ลบของเก่า

---

## ส่วนที่ 1: Trigger AWS Backup Restore Job

อ้างอิง [README.md](./README.md) หัวข้อ `AWS Backup (EFS metadata — automatic)`:

```bash
# หา recovery point ARN ที่ต้องการ
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name <prefix>-vault --region $REGION \
  --query 'RecoveryPoints[*].{Date:CreationDate,Status:Status,ARN:RecoveryPointArn}' --output table

# Start restore job — สร้าง EFS filesystem ใหม่พร้อมข้อมูลที่ restore แล้ว
EFS_ID=$(terraform output -raw efs_file_system_id 2>/dev/null || \
  aws efs describe-file-systems --query 'FileSystems[?Tags[?Key==`Name`&&Value==`<prefix>-clickhouse-data`]].FileSystemId' --output text)

aws backup start-restore-job \
  --recovery-point-arn "<RECOVERY_POINT_ARN>" \
  --iam-role-arn "arn:aws:iam::<ACCOUNT_ID>:role/<prefix>-backup" \
  --metadata "{\"file-system-id\":\"$EFS_ID\",\"newFileSystem\":\"true\",\"CreationToken\":\"restore-$(date +%s)\"}"

# ติดตามสถานะ
aws backup describe-restore-job --restore-job-id <RESTORE_JOB_ID> --region $REGION
```

รอจนสถานะเป็น `COMPLETED` แล้วจด `NEW_EFS_ID` (file-system-id ที่ AWS Backup สร้างให้ — หาได้จาก `aws backup describe-restore-job` field `CreatedResourceArn`)

---

## ส่วนที่ 2: Repoint ClickHouse ECS ไปยัง Filesystem ใหม่ (ชั่วคราว)

ทำตาม [repoint_ECS.md](./repoint_ECS.md) Phase 0–9 ทั้งหมด — สรุปสั้นๆ:

| Phase | สิ่งที่ทำ |
|---|---|
| 0 | ตั้งตัวแปร (`CLUSTER`, `REGION`, `PREFIX`, `NEW_EFS_ID`) |
| 1 | Stop web → worker → clickhouse |
| 2 | สร้าง mount target บน EFS ใหม่ (AWS Backup ไม่สร้างให้อัตโนมัติ) |
| 3 | **ตรวจสอบ path จริงที่ restore ไปวางไว้** — AWS Backup restore ไม่วางข้อมูลที่ path เดิม แต่วางไว้ใต้ `aws-backup-restore_<timestamp>/` เสมอ ต้องเปิด debug access point (root `/`) + one-off Fargate task เพื่อหา path จริงก่อน |
| 4 | สร้าง access point ชี้ path จริงที่เจอ (ไม่ใส่ `CreationInfo` เพราะ path มีอยู่แล้ว) |
| 5 | อนุญาต IAM ชั่วคราวให้ task role เข้าถึง EFS ARN ใหม่ |
| 6 | Register task definition revision ใหม่ |
| 7 | สั่ง service ให้ใช้ revision ใหม่ |
| 8 | Verify ข้อมูล (`SELECT count() FROM langfuse_system.traces` หรือ query อื่นที่เหมาะ) |
| 9 | Start web + worker กลับ |

> ⚠ **ที่นี่ระบบทำงานได้แล้ว แต่ยังไม่ถาวร** — Terraform state ยังไม่รู้จัก EFS ใหม่ และ path ข้อมูลยังซ้อนอยู่ใต้ `aws-backup-restore_<timestamp>/` ไม่ใช่ path มาตรฐาน (`/clickhouse`) ที่ Terraform config คาดหวัง ถ้าไม่ต้องการใช้งานถาวร (แค่ทดสอบ drill) หยุดที่นี่ได้เลย แล้วลบ EFS ใหม่ทิ้งทีหลัง — ถ้าต้องการใช้งานถาวรให้ทำต่อส่วนที่ 3

---

## ส่วนที่ 3: Reconcile ถาวร — ทำให้ Terraform เป็น Source of Truth

### 3.1 ทำความสะอาด path ข้อมูลก่อน import (สำคัญมาก)

Terraform config (`modules/storage/main.tf`) กำหนด access point ไว้ที่ path `/clickhouse` เสมอ แต่ข้อมูลจริงที่ restore มาอยู่ที่ `/aws-backup-restore_<timestamp>/clickhouse` — ถ้า import เข้า state ทั้งที่ path ไม่ตรงกับ config, `terraform plan` จะเห็น diff และพยายาม replace access point ทันที (สร้าง path `/clickhouse` เปล่าใหม่ทับ ซึ่งจะกลับไปเจอปัญหาเดิม)

ต้อง**ย้ายข้อมูลจริงไปที่ path สะอาดก่อน**:

```bash
# 1. Stop web/worker/clickhouse (กันไม่ให้เขียนข้อมูลระหว่างย้าย)
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-web --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-worker --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-clickhouse --desired-count 0 --region $REGION
aws ecs wait services-stable --cluster $CLUSTER --services ${PREFIX}-clickhouse --region $REGION

# 2. เปิด debug access point ที่ root จริง (uid/gid 0, path "/")
DEBUG_AP_ID=$(aws efs create-access-point \
  --file-system-id $NEW_EFS_ID --posix-user Uid=0,Gid=0 --root-directory "Path=/" \
  --region $REGION --query 'AccessPointId' --output text)

# 3. รัน one-off Fargate task mount debug access point (ดูตัวอย่าง task definition
#    เต็มใน repoint_ECS.md Phase 3 — ใช้ image busybox, sleep 600, mountPoints
#    ไปที่ /mnt/efs-root, executionRoleArn/taskRoleArn ใช้ตัวเดิมของ clickhouse)

# 4. Exec เข้า debug task แล้วย้ายข้อมูล
#    ต้องแน่ใจว่า /clickhouse ที่ path เดิม (ถ้ามี) เป็นแค่ directory เปล่าที่ EFS
#    auto-create ผิดพลาดจาก CreationInfo เท่านั้น (ตรวจสอบเนื้อหาก่อน rm เสมอ
#    — อย่า rm -rf แบบไม่เช็คก่อน)
aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'ls -la /mnt/efs-root/clickhouse/'"   # เช็คก่อนว่าเป็น empty bootstrap artifact จริง

aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'rm -rf /mnt/efs-root/clickhouse && mv /mnt/efs-root/aws-backup-restore_*/clickhouse /mnt/efs-root/clickhouse && echo MOVE_DONE'"

# 5. ลบ wrapper directory ที่เหลือ (ตอนนี้ควรว่างแล้ว)
aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'rm -rf /mnt/efs-root/aws-backup-restore_*'"

# 6. Cleanup debug resources
aws ecs stop-task --cluster $CLUSTER --task $DEBUG_TASK_ARN --region $REGION
aws efs delete-access-point --access-point-id $DEBUG_AP_ID --region $REGION
aws ecs deregister-task-definition --task-definition temp-efs-debug:<revision> --region $REGION
```

### 3.2 สร้าง access point สะอาดที่ path มาตรฐาน

```bash
CLEAN_AP_ID=$(aws efs create-access-point \
  --file-system-id $NEW_EFS_ID \
  --posix-user Uid=101,Gid=101 \
  --root-directory "Path=/clickhouse" \
  --region $REGION --query 'AccessPointId' --output text)
```

> ไม่ใส่ `CreationInfo` เพราะ path มีข้อมูลจริงอยู่แล้ว — ถ้า path ผิดจะ error ทันทีตอน mount ดีกว่า silently สร้าง directory เปล่าใหม่ให้

ทำ Phase 6–9 ของ repoint_ECS.md อีกครั้งด้วย access point ตัวใหม่นี้ (register task definition, update service, verify, start web/worker) ก่อนไปขั้นต่อไป

### 3.3 หา mount target ID ให้ตรงกับ subnet index ของ Terraform

Terraform สร้าง `aws_efs_mount_target.clickhouse[N]` โดย `N` = index ของ `var.private_subnet_ids[N]` ต้อง import ให้ตรง index ไม่งั้น apply ครั้งถัดไปจะเห็น subnet_id ไม่ตรงแล้วพยายาม replace:

```bash
# เช็ค subnet order จริงใน state (index 0, 1, 2)
for i in 0 1 2; do
  terraform state show "module.networking.aws_subnet.private[$i]" | grep -E "^\s+id\s+="
done

# Match กับ mount target บน EFS ใหม่
aws efs describe-mount-targets --file-system-id $NEW_EFS_ID --region $REGION \
  --query 'MountTargets[*].{mtId:MountTargetId,subnetId:SubnetId}' --output table
```

จับคู่ subnet ID ให้ตรงกันแล้วจดไว้ (`MT_0`, `MT_1`, `MT_2` ตามลำดับ index)

### 3.4 Backup state ก่อนแก้ (safety net)

```bash
mkdir -p /tmp/tfstate-backup
terraform state pull > /tmp/tfstate-backup/terraform-$(date +%Y%m%d-%H%M%S).tfstate
```

### 3.5 ลบ resource เก่าออกจาก state แล้ว import ตัวใหม่

```bash
# ลบของเก่า (ไม่ได้ลบ resource จริงใน AWS แค่เอาออกจาก Terraform tracking)
terraform state rm \
  'module.storage.aws_efs_mount_target.clickhouse[0]' \
  'module.storage.aws_efs_mount_target.clickhouse[1]' \
  'module.storage.aws_efs_mount_target.clickhouse[2]' \
  'module.storage.aws_efs_access_point.clickhouse' \
  'module.storage.aws_efs_file_system.clickhouse'

# Import ตัวใหม่เข้าที่ address เดิม
terraform import module.storage.aws_efs_file_system.clickhouse $NEW_EFS_ID
terraform import 'module.storage.aws_efs_mount_target.clickhouse[0]' $MT_0
terraform import 'module.storage.aws_efs_mount_target.clickhouse[1]' $MT_1
terraform import 'module.storage.aws_efs_mount_target.clickhouse[2]' $MT_2
terraform import module.storage.aws_efs_access_point.clickhouse $CLEAN_AP_ID
```

### 3.6 ตรวจสอบ plan ก่อน apply

```bash
terraform plan
```

**สิ่งที่ควรเห็น (ปกติ ไม่ใช่ error):**
- `module.storage.aws_efs_access_point.clickhouse` **must be replaced** — เพราะ Terraform config มี `creation_info` (สำหรับ fresh install) แต่ access point ที่ import มาไม่มี `creation_info` (สร้างแบบไม่ใส่ตาม 3.2) เป็น diff ที่ "forces replacement" เสมอ **ปลอดภัย** เพราะ path `/clickhouse` มีข้อมูลอยู่แล้ว AWS จะไม่ยุ่งกับข้อมูลเดิมตอนสร้าง access point ใหม่ (creation_info ใช้แค่ตอน path ไม่มีอยู่)
- `module.ecs_clickhouse.aws_ecs_task_definition.clickhouse` **must be replaced** — เพราะ `file_system_id`/`access_point_id` เปลี่ยน ปกติ
- `module.iam.aws_iam_role_policy.clickhouse_task` **will be updated in-place** — EFS ARN ใน policy เปลี่ยนเป็นตัวใหม่อัตโนมัติ (เพราะ code อ้าง `var.efs_arn` อยู่แล้ว ไม่ต้องแก้ code) **นี่คือขั้นตอน "ย้าย IAM policy เป็นถาวร"**
- `module.backup.aws_backup_selection.efs` **must be replaced** — backup plan จะเริ่ม target EFS ใหม่แทน ปกติ

ถ้าเห็น diff อื่นที่ไม่คาดคิด (เช่น mount target subnet_id เปลี่ยน) แปลว่า index ใน 3.3 จับคู่ผิด ให้ `state rm` + import ใหม่ให้ถูก

### 3.7 Apply แล้ว cutover service

```bash
terraform apply

# หา revision ใหม่ที่ apply สร้างให้
NEW_TD=$(aws ecs list-task-definitions --family-prefix ${PREFIX}-clickhouse --region $REGION --sort DESC --max-items 1 --query 'taskDefinitionArns[0]' --output text)

# Service มี lifecycle.ignore_changes=[task_definition] ต้อง force cutover เอง
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-clickhouse \
  --task-definition $NEW_TD --desired-count 1 --force-new-deployment --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-web --desired-count 1 --force-new-deployment --region $REGION
aws ecs wait services-stable --cluster $CLUSTER --services ${PREFIX}-clickhouse ${PREFIX}-web ${PREFIX}-worker --region $REGION
```

### 3.8 ลบ IAM policy ชั่วคราว

```bash
aws iam delete-role-policy --role-name ${PREFIX}-clickhouse-task --policy-name temp-new-efs-access --region $REGION
```

### 3.9 Verify ครั้งสุดท้าย

```bash
# Terraform ต้องไม่มี diff เหลือ
terraform plan   # ต้องได้ "No changes"

# ข้อมูลต้องยังอยู่ครบ
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name ${PREFIX}-clickhouse --region $REGION --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster $CLUSTER --task $TASK_ARN --container clickhouse --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD --query \\\"SELECT table, count() AS parts, sum(rows) AS rows FROM system.parts WHERE database='langfuse_system' GROUP BY table FORMAT PrettyCompact\\\"\""
```

---

## ส่วนที่ 4: ลบ EFS เก่า

ทำเฉพาะหลังยืนยันแล้วว่า EFS ใหม่ทำงานถูกต้องสมบูรณ์ (3.9 ผ่านหมด) — EFS ต้องลบ mount target + access point ก่อน จึงลบ filesystem ได้:

```bash
OLD_EFS_ID=<EFS ID เดิม ก่อน restore>

# ลบ access point ของเก่า
for AP in $(aws efs describe-access-points --file-system-id $OLD_EFS_ID --region $REGION --query 'AccessPoints[*].AccessPointId' --output text); do
  aws efs delete-access-point --access-point-id $AP --region $REGION
done

# ลบ mount target ของเก่า
for MT in $(aws efs describe-mount-targets --file-system-id $OLD_EFS_ID --region $REGION --query 'MountTargets[*].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $MT --region $REGION
done

# รอให้ mount target หายหมดก่อนลบ filesystem
aws efs describe-mount-targets --file-system-id $OLD_EFS_ID --region $REGION --query 'length(MountTargets)'

# ลบ filesystem เก่า
aws efs delete-file-system --file-system-id $OLD_EFS_ID --region $REGION
```

---

## บทเรียน / จุดที่พลาดง่าย (สรุปจากการทำจริง)

1. **AWS Backup restore ไม่ preserve path เดิม** — วางข้อมูลไว้ใต้ `aws-backup-restore_<timestamp>/` เสมอ ไม่ใช่ path จริงของ filesystem ต้นฉบับ ต้องตรวจสอบก่อนสร้าง access point ทุกครั้ง (ส่วนที่ 2 Phase 3)
2. **`CreationInfo` ใน access point เป็นดาบสองคม** — ถ้า path ไม่มีอยู่จริง มันจะสร้าง directory เปล่าใหม่ให้แบบไม่ error เลย ทำให้เข้าใจผิดว่า mount สำเร็จแล้วข้อมูลอยู่ครบ ทั้งที่จริงมองไม่เห็นข้อมูลที่ restore มาเลย
3. **zsh ไม่ word-split เหมือน bash** — `for X in $VAR` ที่มีค่าหลายตัวคั่นด้วย tab/space จะไม่ split ใน zsh ใช้ `tr` + `while read` แทนเสมอ (ดู repoint_ECS.md Phase 2)
4. **`--force-new-deployment` ไม่เปลี่ยน task definition revision ที่ service ใช้** ถ้า service มี `lifecycle.ignore_changes=[task_definition]` ต้องระบุ `--task-definition <ARN ใหม่>` ตรงๆ เสมอ
5. **IAM policy ที่ scope ด้วย EFS ARN เฉพาะ** ต้องอัปเดตให้ตรง EFS ตัวใหม่ก่อน service จะ mount ได้ (แม้ security group/mount target ถูกต้องแล้วก็ตาม)
6. **Import mount target ต้อง match subnet index ให้ตรงกับ Terraform** ไม่งั้น apply ครั้งถัดไปจะเห็น subnet_id ไม่ตรงแล้วพยายาม replace
7. **`creation_info` diff ตอน import จะบังคับ replace access point เสมอ** — เป็นเรื่องปกติ ไม่ใช่ error ต้อง apply เพื่อให้ Terraform สร้างใหม่แบบมี `creation_info` (ปลอดภัยเพราะ path มีข้อมูลอยู่แล้ว)
