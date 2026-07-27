# Manual Repoint ECS Mount to New EFS Filesystem (Post-Restore Runbook)

เอกสารนี้เป็นขั้นตอนละเอียดสำหรับ repoint ClickHouse ECS task ไปยัง EFS filesystem ใหม่ที่ได้จาก AWS Backup restore job — ใช้ต่อจาก [TEST_PLAN_BACKUP_RESTORE.md](./TEST_PLAN_BACKUP_RESTORE.md) TC-EFS-04 (หลัง `aws backup start-restore-job` เสร็จ ได้ EFS filesystem ใหม่ที่มีข้อมูล restore แล้ว แต่ยังไม่มี mount target/access point และยังไม่ได้ผูกกับ ECS)

> อ้างอิง [README.md](./README.md) หัวข้อ `AWS Backup (EFS metadata — automatic)` สำหรับวิธีสร้าง recovery point และเริ่ม restore job

---

## Phase 0: ตั้งตัวแปร

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
REGION=<region ที่ deploy>
PREFIX=<name_prefix>-<environment>   # เช่น pitchayasak-lfch-poc
NEW_EFS_ID=<EFS ID ใหม่จาก restore job>
```

---

## Phase 1: Stop web → worker → clickhouse (เรียงลำดับ)

หยุด web/worker ก่อนเพื่อไม่ให้เขียนข้อมูลระหว่าง repoint แล้วค่อยหยุด ClickHouse เพื่อปลดล็อค EFS เดิม:

```bash
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-web --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-worker --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-clickhouse --desired-count 0 --region $REGION
```

รอจน task หยุดจริง (ไม่ใช่แค่ desired-count เปลี่ยน):

```bash
aws ecs wait services-stable --cluster $CLUSTER --services ${PREFIX}-clickhouse --region $REGION
```

---

## Phase 2: สร้าง mount target บน EFS ใหม่

> ⚠ **AWS Backup restore สร้างแค่ filesystem เปล่าๆ ไม่สร้าง mount target ให้อัตโนมัติ** — ถ้าข้ามขั้นนี้ ECS task จะ mount ไม่ได้เลยเพราะไม่มี network endpoint ให้เชื่อม

```bash
VPC_ID=$(terraform output -raw vpc_id)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PREFIX}-private-*" --region $REGION --query 'Subnets[*].SubnetId' --output text)
EFS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-efs-*" --region $REGION --query 'SecurityGroups[0].GroupId' --output text)

echo "$SUBNET_IDS" | tr -s '[:space:]' '\n' | while read -r SUBNET; do
  [ -z "$SUBNET" ] && continue
  aws efs create-mount-target --file-system-id $NEW_EFS_ID --subnet-id $SUBNET --security-groups $EFS_SG_ID --region $REGION
done
```

> ใช้ `tr` + `while read` แทน `for SUBNET in $SUBNET_IDS` เพราะ zsh ไม่ word-split unquoted variable ใน `for...in` แบบเดียวกับ bash (subnet ID ทั้งหมดจะถูกส่งเป็นค่าเดียวกันไปที่ `--subnet-id` ทำให้ `ValidationException`) — pattern นี้ทำงานเหมือนกันทั้ง bash และ zsh

รอจนทุก mount target `available`:

```bash
aws efs describe-mount-targets --file-system-id $NEW_EFS_ID --region $REGION --query 'MountTargets[*].LifeCycleState'
```

---

## Phase 3: ตรวจสอบ path จริงที่ AWS Backup วางข้อมูล restore ไว้

> ⚠ **จุดที่พลาดง่ายที่สุดอันดับหนึ่ง:** AWS Backup restore EFS ไปยัง filesystem ใหม่ **ไม่ได้วางข้อมูลไว้ที่ path เดิม** (`/clickhouse`) — มันสร้าง subdirectory ใหม่ชื่อ `aws-backup-restore_<timestamp>/` แล้ววางข้อมูลที่ restore ไว้ข้างในนั้นแทน (เช่น `/aws-backup-restore_2026-07-27T05-06-24-914181044Z/clickhouse/...`) ถ้าสร้าง access point ชี้ที่ `/clickhouse` ตรงๆ โดยไม่เช็คก่อน EFS จะใช้ `CreationInfo` สร้าง directory เปล่าใหม่ให้แทนที่จะ error — ClickHouse จะ mount สำเร็จแต่มองไม่เห็นข้อมูลที่ restore มาเลย (ไม่มี error ให้เห็นตอนนั้นด้วย)

สร้าง access point ชั่วคราวที่ root จริงของ filesystem เพื่อดูโครงสร้างจริงก่อน:

```bash
DEBUG_AP_ID=$(aws efs create-access-point \
  --file-system-id $NEW_EFS_ID \
  --posix-user Uid=0,Gid=0 \
  --root-directory "Path=/" \
  --region $REGION \
  --query 'AccessPointId' --output text)
```

Mount ผ่าน one-off Fargate task (busybox) เพื่อดู top-level structure — ใช้ execution role/task role เดิมของ ClickHouse:

```bash
EXEC_ROLE_ARN=$(aws ecs describe-task-definition --task-definition ${PREFIX}-clickhouse --region $REGION --query 'taskDefinition.executionRoleArn' --output text)
TASK_ROLE_ARN=$(aws ecs describe-task-definition --task-definition ${PREFIX}-clickhouse --region $REGION --query 'taskDefinition.taskRoleArn' --output text)

cat > /tmp/debug-td.json << JSON
{
  "family": "temp-efs-debug",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "containerDefinitions": [{
    "name": "debug",
    "image": "public.ecr.aws/docker/library/busybox:latest",
    "entryPoint": ["/bin/sh", "-c"],
    "command": ["sleep 600"],
    "mountPoints": [{"sourceVolume": "efs-root", "containerPath": "/mnt/efs-root"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {"awslogs-group": "/ecs/${PREFIX}-clickhouse", "awslogs-region": "$REGION", "awslogs-stream-prefix": "debug"}
    }
  }],
  "volumes": [{
    "name": "efs-root",
    "efsVolumeConfiguration": {
      "fileSystemId": "$NEW_EFS_ID",
      "transitEncryption": "ENABLED",
      "authorizationConfig": {"accessPointId": "$DEBUG_AP_ID", "iam": "DISABLED"}
    }
  }]
}
JSON

aws ecs register-task-definition --cli-input-json file:///tmp/debug-td.json --region $REGION --query 'taskDefinition.taskDefinitionArn' --output text
```

รัน one-off task ผ่าน security group เดียวกับ EFS mount target (จาก Phase 2):

```bash
SUBNETS_JSON=$(echo "$SUBNET_IDS" | tr -s '[:space:]' '\n' | jq -R . | jq -s -c .)

DEBUG_TASK_ARN=$(aws ecs run-task \
  --cluster $CLUSTER --task-definition temp-efs-debug \
  --launch-type FARGATE --enable-execute-command \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":$SUBNETS_JSON,\"securityGroups\":[\"$EFS_SG_ID\"],\"assignPublicIp\":\"DISABLED\"}}" \
  --region $REGION --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-running --cluster $CLUSTER --tasks $DEBUG_TASK_ARN --region $REGION
```

ดู top-level structure — หา directory ชื่อ `aws-backup-restore_<timestamp>`:

```bash
aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'ls -la /mnt/efs-root/'"
```

ดูข้างในว่ามี `clickhouse/` ซ้อนอยู่ไหม แล้วยืนยันว่ามีตารางจริงอยู่ (เช่น `traces.sql`):

```bash
aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'ls -la /mnt/efs-root/aws-backup-restore_*/clickhouse/metadata/langfuse_system/ 2>&1'"
```

จด path จริงไว้ใช้ในขั้นถัดไป:

```bash
REAL_PATH=/aws-backup-restore_<timestamp ที่เจอจริง>/clickhouse
```

Cleanup debug resources:

```bash
aws ecs stop-task --cluster $CLUSTER --task $DEBUG_TASK_ARN --region $REGION
aws efs delete-access-point --access-point-id $DEBUG_AP_ID --region $REGION
aws ecs deregister-task-definition --task-definition temp-efs-debug:1 --region $REGION
```

---

## Phase 4: สร้าง access point ใหม่ ชี้ path จริงที่ตรวจสอบแล้ว (uid/gid 101)

```bash
NEW_AP_ID=$(aws efs create-access-point \
  --file-system-id $NEW_EFS_ID \
  --posix-user Uid=101,Gid=101 \
  --root-directory "Path=$REAL_PATH" \
  --region $REGION \
  --query 'AccessPointId' --output text)
echo $NEW_AP_ID
```

> ไม่ใส่ `CreationInfo` ในขั้นนี้เพราะ path นี้ควรมีอยู่แล้วจากการ restore (ยืนยันแล้วใน Phase 3) — ถ้า path ผิด mount จะ error ทันทีตอน start container ดีกว่า silently สร้าง directory เปล่าใหม่ให้แบบที่พลาดได้ง่ายตอนใส่ `CreationInfo`

---

## Phase 5: อนุญาต IAM ให้ ClickHouse task role เข้าถึง EFS ตัวใหม่

> ⚠ **จุดที่พลาดง่ายที่สุด:** task definition ตั้ง `authorization_config { iam = "ENABLED" }` ไว้ (`modules/ecs_clickhouse/main.tf`) ดังนั้น IAM policy ของ task role ต้องอนุญาต EFS ARN ตัวใหม่ด้วย ไม่งั้น mount จะ fail ด้วย permission denied แม้ security group/mount target จะถูกต้องแล้ว — policy เดิมใน `modules/iam/main.tf` (`EFSAccess` statement) scope ไว้เฉพาะ EFS ARN เดิมเท่านั้น

```bash
ROLE_NAME=${PREFIX}-clickhouse-task
NEW_EFS_ARN=$(aws efs describe-file-systems --file-system-id $NEW_EFS_ID --region $REGION --query 'FileSystems[0].FileSystemArn' --output text)

aws iam put-role-policy --role-name $ROLE_NAME --policy-name temp-new-efs-access --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"],
    "Resource": "$NEW_EFS_ARN"
  }]
}
EOF
)"
```

---

## Phase 6: Register task definition revision ใหม่ ชี้ EFS/access point ใหม่

```bash
aws ecs describe-task-definition --task-definition ${PREFIX}-clickhouse --region $REGION --query 'taskDefinition' > /tmp/clickhouse-td.json

jq --arg efs "$NEW_EFS_ID" --arg ap "$NEW_AP_ID" \
  '.volumes[0].efsVolumeConfiguration.fileSystemId = $efs |
   .volumes[0].efsVolumeConfiguration.authorizationConfig.accessPointId = $ap |
   del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)' \
  /tmp/clickhouse-td.json > /tmp/clickhouse-td-new.json

NEW_TD_ARN=$(aws ecs register-task-definition --cli-input-json file:///tmp/clickhouse-td-new.json --region $REGION --query 'taskDefinition.taskDefinitionArn' --output text)
echo $NEW_TD_ARN
```

---

## Phase 7: สั่ง ClickHouse service ให้ใช้ revision ใหม่และ start

```bash
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-clickhouse \
  --task-definition $NEW_TD_ARN --desired-count 1 --force-new-deployment --region $REGION

aws ecs wait services-stable --cluster $CLUSTER --services ${PREFIX}-clickhouse --region $REGION
```

---

## Phase 8: Verify ข้อมูล (เหมือน TC-CLUSTER-02 ใน TEST_PLAN_BACKUP_RESTORE.md)

```bash
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name ${PREFIX}-clickhouse --region $REGION --query 'taskArns[0]' --output text)

aws ecs execute-command --cluster $CLUSTER --task $TASK_ARN --container clickhouse --interactive --region $REGION \
  --command "clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD --query \"SELECT count() FROM langfuse_system.traces\""
```

เทียบ row count กับ baseline ที่บันทึกไว้ก่อน restore

---

## Phase 9: Start web + worker กลับ

```bash
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-web --desired-count 1 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${PREFIX}-worker --desired-count 1 --region $REGION
```

ไม่ต้องแก้อะไรฝั่ง web/worker เพราะยังต่อผ่าน service-discovery DNS เดิม (`clickhouse.langfuse.local`) — ไม่เปลี่ยน

---

## ⚠ สิ่งสำคัญที่ต้องรู้: Terraform state จะ drift หลังจากนี้

เพราะขั้นตอนทั้งหมดข้างต้นทำผ่าน AWS CLI ตรงๆ ไม่ผ่าน Terraform ตอนนี้ state ยังคิดว่า ClickHouse ใช้ EFS **เดิม** แต่ service จริงชี้ไป `$NEW_EFS_ID` แล้ว — `terraform plan` ครั้งถัดไปจะพยายามสร้าง task definition revision ใหม่ที่ชี้กลับ EFS เดิม (เพราะ `lifecycle.ignore_changes=[task_definition]` มันจะไม่ auto-apply กับ service จริงๆ แต่ก็ยัง confusing ในระยะยาว)

**ต้องเลือกทำอย่างใดอย่างหนึ่งก่อนใช้งานต่อเนื่อง:**

1. **Copy ข้อมูลกลับ EFS เดิม (แนะนำ)** — mount ทั้งสอง EFS บน EC2/Fargate ชั่วคราว, `rsync` ข้อมูลจาก `$NEW_EFS_ID` กลับไป EFS เดิม, แล้ว repoint กลับไปใช้ config เดิม (revert Phase 6-7), ลบ policy ชั่วคราวจาก Phase 5 (`aws iam delete-role-policy --role-name $ROLE_NAME --policy-name temp-new-efs-access`), ลบ `$NEW_EFS_ID` ทิ้ง

2. **Import EFS ใหม่เข้า Terraform state แทนของเดิม** (ซับซ้อนกว่า เสี่ยงกว่า) — `terraform state rm` + `terraform import` สำหรับ `aws_efs_file_system.clickhouse`, `aws_efs_mount_target.clickhouse[*]`, `aws_efs_access_point.clickhouse` ทั้งหมด แล้วย้าย IAM policy จาก inline (Phase 5) เข้าไปอยู่ใน `modules/iam/main.tf` แบบถาวร, ลบ EFS เก่าด้วยมือ

ไม่ควรปล่อย state drift ค้างไว้นานเกินไป
