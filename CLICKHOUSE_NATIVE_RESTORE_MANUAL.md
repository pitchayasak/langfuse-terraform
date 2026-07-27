# ClickHouse Native Backup & Restore Manual

เอกสารนี้เป็น manual สำหรับ ClickHouse native `BACKUP`/`RESTORE` command (เก็บสำเนาข้อมูลแยกอิสระใน S3) — เขียนจากการทดสอบจริงที่ทำและ debug bug มาแล้วครบ รวมทุกจุดที่พลาดง่าย

**ต่างจาก [EFS_RESTORE_MANUAL.md](./EFS_RESTORE_MANUAL.md) ยังไง:** native backup/restore เป็นกลไกที่**เป็นอิสระจาก EFS โดยสิ้นเชิง** — ไม่แตะ EFS เลยทั้งตอน backup และ restore ป้องกันคนละสถานการณ์กับ EFS backup (ดูส่วนที่ 4)

---

## ส่วนที่ 1: Run a Backup

### 1.1 ตั้งตัวแปรและรัน

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
REGION=<region ที่ deploy>

# Bucket แยกต่างหากสำหรับเก็บ native backup — ไม่ใช้ bucket เดียวกับ
# s3_clickhouse_bucket_name (ที่เก็บ S3 data parts จริงของ ClickHouse)
# เพื่อไม่ให้ backup ปะปนกับข้อมูล live ในถังเดียวกัน
BACKUP_BUCKET=psena-poc-th

TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name ${CLUSTER}-clickhouse \
  --region $REGION \
  --query 'taskArns[0]' --output text)

TODAY=$(date +%Y-%m-%d)

aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"BACKUP DATABASE langfuse_system \
    TO S3('https://$BACKUP_BUCKET.s3.$REGION.amazonaws.com/native-backups/$TODAY/', '', '')\\\"\""
```

> ⚠ **บั๊กที่พบจากการทดสอบจริง:** ต้อง pre-compute `$TODAY` ในเชลล์ฝั่ง local ก่อนแล้ว interpolate เข้าไปตรงๆ (เหมือนตัวอย่างข้างบน) — ห้ามใช้ `\$(date +%Y-%m-%d)` (escape ไว้ให้ประมวลผลฝั่ง remote) เพราะ ECS Exec **ไม่ evaluate อะไรเลยฝั่ง remote ถ้าไม่มี shell ครอบ** คำสั่งข้างบนครอบด้วย `sh -c "..."` ไว้แล้วเพื่อให้ `\$CLICKHOUSE_PASSWORD` expand ถูกต้อง — **ถ้าไม่ครอบ `sh -c` แม้แต่ `\$CLICKHOUSE_PASSWORD` (plain variable ธรรมดา) ก็ไม่ expand เหมือนกัน** จะได้ literal string `$CLICKHOUSE_PASSWORD` ส่งเป็น password ตรงๆ ทำให้ authentication fail (ดูส่วนที่ 6 ข้อ 6 สำหรับรายละเอียด) — ส่วน `\$(date +%Y-%m-%d)` ต่อให้ครอบ `sh -c` แล้วก็ยังต้อง pre-compute เป็นตัวแปรธรรมดาก่อนอยู่ดี เพราะ command substitution ซ้อนอยู่ใน SQL string literal ทำให้ escape ยุ่งยากขึ้นไปอีกชั้น ไม่คุ้มเสี่ยง

Argument `'', ''` ว่างเปล่าตั้งใจให้ ClickHouse ใช้ ECS task IAM role แทน credential ตรงๆ (ดู `modules/iam/main.tf` statement `S3BackupAccess` — ให้สิทธิ์เข้าถึง `$BACKUP_BUCKET` แยกจาก `S3DiskAccess` ที่ให้สิทธิ์ bucket ข้อมูล live)

### 1.2 ตรวจสอบสถานะ

```bash
aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"SELECT * FROM system.backups ORDER BY start_time DESC LIMIT 5 FORMAT Vertical\\\"\""
```

ต้องเห็น status `BACKUP_CREATED`

### 1.3 ดู backup ที่มีอยู่ทั้งหมด (ไม่ต้องพึ่ง ClickHouse instance)

```bash
aws s3 ls s3://$BACKUP_BUCKET/native-backups/ --region $REGION
```

> เก็บ prefix `native-backups/YYYY-MM-DD/` ใน `$BACKUP_BUCKET` ซึ่งเป็นคนละ bucket กับ S3 data parts จริง (prefix `data/` ใน `s3_clickhouse_bucket_name`) โดยตั้งใจ — ตำแหน่งนี้เป็นแค่ธรรมเนียมการตั้งชื่อที่รู้อยู่แล้ว **ไม่ได้ขึ้นกับ EFS เลย** ต่อให้ EFS หายไปทั้งหมด backup ที่นี่ก็ยังหาเจอผ่าน `aws s3 ls` ตรงๆ

---

## ส่วนที่ 2: Restore

### 2.1 บันทึก baseline ก่อน restore (precondition)

```bash
aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"SELECT table, count() AS parts, sum(rows) AS total_rows FROM system.parts WHERE database='langfuse_system' AND active GROUP BY table ORDER BY table FORMAT PrettyCompact\\\"\""
```

จดผลลัพธ์ไว้เทียบหลัง restore

### 2.2 Stop web + worker (กันเขียนข้อมูลระหว่าง restore)

```bash
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 0 --region $REGION
```

### 2.3 Restore

```bash
TODAY=$(date +%Y-%m-%d)   # หรือวันที่ backup ที่ต้องการ restore

aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"RESTORE DATABASE langfuse_system FROM S3('https://$BACKUP_BUCKET.s3.$REGION.amazonaws.com/native-backups/$TODAY/', '', '')\\\"\""
```

ต้องเห็นสถานะ `RESTORED`

> ⚠ ถ้า error ว่า database มีอยู่แล้ว (`already exists`) — บาง version ของ ClickHouse ต้องการให้ database ปลายทางไม่มีอยู่ก่อน ไม่ใช่แค่ว่างเปล่า ให้ `DROP DATABASE langfuse_system` (เฉพาะกรณีที่ยืนยันแล้วว่าไม่มีข้อมูลสำคัญค้างอยู่) แล้วรัน RESTORE ใหม่ทันที ไม่ต้อง stop/start service ซ้ำ

### 2.4 Start web + worker กลับ

```bash
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 1 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 1 --region $REGION
```

### 2.5 Verify เทียบ baseline

```bash
aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"SELECT table, count() AS parts, sum(rows) AS total_rows FROM system.parts WHERE database='langfuse_system' AND active GROUP BY table ORDER BY table FORMAT PrettyCompact\\\"\""
```

Row count ต้องตรงกับ baseline ใน 2.1

---

## ส่วนที่ 3: ทดสอบแบบ Clean-Room (พิสูจน์ว่า restore ไม่พึ่งข้อมูล live ที่เหลืออยู่)

การทดสอบปกติ (ส่วนที่ 2) อาจไม่พิสูจน์ชัดว่า restore ดึงข้อมูลจาก backup จริง หรือแค่ข้อมูล live เดิมยังอยู่ ถ้าต้องการทดสอบแบบเข้มงวดขึ้น (ลบข้อมูล live ทั้งหมดก่อน restore):

### 3.1 Drop database + ลบ S3 data prefix

```bash
# 1. Drop database (ตอน ClickHouse ยังรันปกติ)
aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD --query \\\"DROP DATABASE langfuse_system\\\"\""

# 2. Stop ทั้ง web/worker/clickhouse
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-web --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-worker --desired-count 0 --region $REGION
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-clickhouse --desired-count 0 --region $REGION
aws ecs wait services-stable --cluster $CLUSTER --services ${CLUSTER}-clickhouse --region $REGION

# 3. ลบเฉพาะ prefix data/ บน bucket ข้อมูล live (s3_clickhouse_bucket_name)
CH_BUCKET=$(terraform output -raw s3_clickhouse_bucket_name)
aws s3 ls s3://$CH_BUCKET/data/ --recursive --region $REGION   # preview ก่อน
aws s3 rm s3://$CH_BUCKET/data/ --recursive --region $REGION

# 4. ยืนยันว่า backup ใน $BACKUP_BUCKET ยังอยู่ครบ (คนละ bucket กัน จึงไม่ถูกกระทบเลย)
aws s3 ls s3://$BACKUP_BUCKET/native-backups/ --recursive --region $REGION
```

> เพราะ native backup อยู่คนละ bucket กับข้อมูล live ตั้งแต่แรก (`$BACKUP_BUCKET` แยกจาก `$CH_BUCKET`) การลบ prefix `data/` บน `$CH_BUCKET` จึง**ไม่มีทางกระทบ backup ใน `$BACKUP_BUCKET` เลย** — ปลอดภัยกว่าตอนที่ทั้งสองอยู่ bucket เดียวกัน

> ⚠ **จุดที่พังง่ายที่สุด:** ตาราง `system.*` ภายในของ ClickHouse เอง (เช่น `system.zookeeper_connection_log`, `query_log`, `part_log`) ใช้ storage policy `s3_main` เดียวกันกับ `langfuse_system` (default ของทั้ง deployment) การลบ prefix `data/` ทั้งหมดจึงกระทบตาราง system ภายในด้วย ไม่ใช่แค่ `langfuse_system` — ผลคือ **ClickHouse จะ crash loop ตอน boot ครั้งถัดไป** ด้วย error แบบ:
> ```
> Code: 722. DB::Exception: Waited job failed: ... Code: 499. DB::Exception: The specified key does not exist ...
> Cannot attach table `system`.`zookeeper_connection_log` from metadata file ...
> ```
> เพราะ metadata บน EFS ยังอ้างอิง S3 key ที่เพิ่งถูกลบไป นี่คือพฤติกรรมที่คาดไว้ ไม่ใช่ bug ของ ClickHouse — แก้ตามข้อ 3.2

### 3.2 กู้จาก crash loop (ถ้าเจอ)

ล้าง EFS metadata ทั้งหมดให้ ClickHouse boot ใหม่แบบสะอาด (ข้อมูลใน S3 `data/` หายไปแล้วอยู่ดี เก็บ metadata เดิมไว้ก็ไม่มีประโยชน์) — ดูขั้นตอนเต็มใน [repoint_ECS.md](./repoint_ECS.md) รูปแบบเดียวกับการ mount debug access point:

```bash
# 1. Stop clickhouse (ถ้ายังไม่ได้ stop)
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-clickhouse --desired-count 0 --region $REGION
aws ecs wait services-stable --cluster $CLUSTER --services ${CLUSTER}-clickhouse --region $REGION

# 2. สร้าง debug access point ที่ root จริง (uid/gid 0, path "/")
EFS_ID=<clickhouse EFS file system id>
DEBUG_AP_ID=$(aws efs create-access-point \
  --file-system-id $EFS_ID --posix-user Uid=0,Gid=0 --root-directory "Path=/" \
  --region $REGION --query 'AccessPointId' --output text)

# 3. รัน one-off Fargate debug task mount ที่ /mnt/efs-root
#    (ดู task definition ตัวอย่างเต็มใน repoint_ECS.md ส่วนที่ 3
#    — ใช้ execution/task role เดิมของ clickhouse, image busybox)

# 4. ล้าง metadata ทั้งหมดใต้ /clickhouse (เก็บ directory เปล่าไว้ ลบแค่เนื้อหา)
aws ecs execute-command --cluster $CLUSTER --task $DEBUG_TASK_ARN --container debug --interactive --region $REGION \
  --command "sh -c 'rm -rf /mnt/efs-root/clickhouse/* && echo WIPE_DONE'"

# 5. Cleanup debug resources
aws ecs stop-task --cluster $CLUSTER --task $DEBUG_TASK_ARN --region $REGION
aws efs delete-access-point --access-point-id $DEBUG_AP_ID --region $REGION

# 6. Start ClickHouse ใหม่ — ควร boot สะอาด (langfuse_system จะถูกสร้างใหม่แบบว่างเปล่า
#    อัตโนมัติจาก env var CLICKHOUSE_DB=langfuse_system)
aws ecs update-service --cluster $CLUSTER --service ${CLUSTER}-clickhouse --desired-count 1 --region $REGION
aws ecs wait services-stable --cluster $CLUSTER --services ${CLUSTER}-clickhouse --region $REGION
```

Verify ว่า boot สำเร็จและ `langfuse_system` ว่างจริง:

```bash
aws ecs execute-command --cluster $CLUSTER --task $TASK_ARN --container clickhouse --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD --query \\\"SELECT count() FROM system.tables WHERE database='langfuse_system'\\\"\""
```

ต้องได้ `0` — จากนั้นไปต่อส่วนที่ 2.3 (RESTORE) ได้เลย ผลลัพธ์ที่ได้พิสูจน์ชัดเจนว่า native BACKUP/RESTORE เก็บสำเนาข้อมูลแยกอิสระจริง ไม่พึ่งพา live data หรือ EFS metadata เดิมเลยแม้แต่น้อย

---

## ส่วนที่ 4: ความสัมพันธ์กับ EFS Backup (สำคัญ — อย่าเข้าใจผิด)

Native backup/restore กับ EFS backup **เป็นอิสระจากกันโดยสิ้นเชิง ไม่มีฝั่งไหนอ้างอิงอีกฝั่ง**:

- **Native BACKUP** เขียนสำเนาไป S3 ตรงๆ (`native-backups/<date>/`) — ไม่แตะ EFS เลยแม้แต่ไฟล์เดียว
- **EFS backup (AWS Backup)** snapshot เฉพาะสิ่งที่อยู่บน EFS ตอนนั้น (schema, S3 disk pointer, Keeper state) — ไม่มีกลไกไหนบันทึกตำแหน่งของ native backup ไว้ เพราะ native backup ไม่ทิ้งร่องรอยบน EFS ให้ snapshot ได้ตั้งแต่แรก

**ลำดับการรัน (native ก่อน/หลัง EFS) ไม่มีผลอะไรเลย** — ตำแหน่งของ native backup เป็นแค่ธรรมเนียมตั้งชื่อ path ที่รู้อยู่แล้ว (`s3://<bucket>/native-backups/<date>/`) หาได้ผ่าน `aws s3 ls` ตรงๆ โดยไม่ต้องพึ่ง EFS เลย

**ทั้งสองป้องกันคนละสถานการณ์:**

| สถานการณ์ | ป้องกันด้วย | เพราะ |
|---|---|---|
| EFS หาย แต่ S3 `data/` ยังอยู่ครบ | EFS backup | S3 data ที่ยังอยู่จะกลายเป็น orphan กู้ไม่ได้ถ้าไม่มี metadata มาบอกว่า part ไหนคือของตารางไหน (ดูเหตุผลละเอียดใน README.md หัวข้อ Layered Backup Strategy) |
| ข้อมูลจริงใน S3 หายไปเอง (ลบผิด, bug, ฯลฯ) | Native backup | มีสำเนาข้อมูลแยกอิสระใน `native-backups/` ที่ไม่ขึ้นกับ live data เลย (พิสูจน์แล้วในส่วนที่ 3) |

สิ่งที่ควรทำจริงคือ**ให้แต่ละอันมีความถี่ที่เหมาะสมกับความเสี่ยงที่มันป้องกัน** (EFS รายวัน, native รายสัปดาห์ + ก่อน migration ตาม README) ไม่ใช่เรื่องลำดับก่อนหลัง

### 4.1 ทำไม EFS backup ไม่มีประโยชน์เลยในสถานการณ์ "S3 data หายไปเอง"

จุดที่มักเข้าใจผิด: ในสถานการณ์ **S3 data หายไปเอง** (เช่นที่จำลองไว้ในส่วนที่ 3) การ restore EFS backup (แทนที่จะล้างทิ้ง) **ไม่ช่วยอะไรเลยแม้แต่น้อย** เหตุผล:

EFS backup เก็บแค่ "แผนที่" (metadata ที่บอกว่า part ไหนอยู่ S3 key ไหน) — ถ้า restore EFS backup เก่ากลับมา ก็ยังได้แผนที่ที่ชี้ไปยัง **S3 key เดิม ซึ่งถูกลบไปแล้วเหมือนกัน** ไม่ต่างจาก metadata ปัจจุบันที่มีอยู่แล้วเลย เพราะปัญหาไม่ได้อยู่ที่ metadata ผิด/หาย แต่อยู่ที่**สิ่งที่ metadata ชี้ไปหายไปต่างหาก** ต่อให้ restore EFS backup จากเมื่อวานหรือเมื่อสัปดาห์ก่อน ก็ยังชี้ไปที่ S3 key เดิมที่หายไปแล้วอยู่ดี — นี่คือเหตุผลที่ขั้นตอนกู้คืนในส่วนที่ 3.2 คือ**ล้าง** metadata ทิ้งแล้วให้ boot ใหม่สะอาด ไม่ใช่**restore** EFS backup

**สรุปเป็นตาราง — backup ไหนช่วยอะไรจริง:**

| สถานการณ์ | EFS backup ช่วยไหม | Native backup ช่วยไหม |
|---|---|---|
| EFS หาย/พัง, S3 data ยังอยู่ | ✅ ช่วย (เร็ว — copy แค่ metadata ไม่ต้อง copy ข้อมูลจริงทั้งหมด, ได้ข้อมูลล่าสุดจริงเพราะ S3 ยังอยู่ครบ) | ⚠️ ช่วยได้แต่อาจเก่ากว่า EFS backup (native backup รันแค่รายสัปดาห์ ไม่ real-time) |
| S3 data หายไปเอง (ลบผิด, bug) | ❌ ไม่ช่วยเลย — metadata ที่ restore มาชี้ไปยัง S3 key ที่หายไปแล้วเหมือนกัน ต้อง**ล้าง**ไม่ใช่**restore** | ✅ ช่วย (มีสำเนาแยกอิสระใน `native-backups/`) |

นี่คือเหตุผลที่ README เรียกกลยุทธ์นี้ว่า "Layered Strategy" — แต่ละชั้นตั้งใจครอบคลุมแค่สถานการณ์เดียว ไม่ใช่ backup ทั่วไปที่ครอบคลุมทุกอย่าง มี EFS backup ไม่ได้แปลว่าไม่ต้องมี native backup และมี native backup ก็ไม่ได้แปลว่าไม่ต้องมี EFS backup

---

## ส่วนที่ 5: ข้อจำกัด — Whole-Database-Only

Native BACKUP/RESTORE ในระบบนี้ทำงานระดับ database (`BACKUP DATABASE langfuse_system`) เท่านั้น ไม่มีตัวอย่างการ restore เฉพาะ table ที่ผ่านการทดสอบยืนยันแล้ว ถ้าต้องการทดสอบพฤติกรรมจริงของการ restore แบบเจาะจง table:

```bash
aws ecs execute-command \
  --cluster $CLUSTER --task $TASK_ARN --container clickhouse \
  --interactive --region $REGION \
  --command "sh -c \"clickhouse-client -u langfuse --password \$CLICKHOUSE_PASSWORD \
    --query \\\"RESTORE TABLE langfuse_system.traces FROM S3('https://$BACKUP_BUCKET.s3.$REGION.amazonaws.com/native-backups/$TODAY/', '', '')\\\"\""
```

บันทึกพฤติกรรมจริงที่เกิดขึ้น (สำเร็จบางส่วน, ต้อง restore ทั้ง database, หรือ ClickHouse คืน error ชัดเจน) — อ้างอิง [TEST_PLAN_BACKUP_RESTORE.md](./TEST_PLAN_BACKUP_RESTORE.md) TC-CHBK-04

---

## บทเรียน / จุดที่พลาดง่าย (สรุปจากการทำจริง)

1. **`clickhouse-client` ที่รันผ่าน `aws ecs execute-command` ต้องครอบด้วย `sh -c "..."` เสมอ** ไม่งั้นไม่มี shell ฝั่ง remote มา evaluate อะไรเลยแม้แต่ plain variable — ยืนยันจากการทดสอบจริง 2 แบบ:
   - `\$(date +%Y-%m-%d)` (command substitution) ไม่ evaluate → ได้ error `Bad URI syntax` เพราะ ClickHouse เห็น literal string `$(date +%Y-%m-%d)` เป็นส่วนหนึ่งของ URI
   - `\$CLICKHOUSE_PASSWORD` (plain variable) **ก็ไม่ evaluate เหมือนกัน** ถ้าไม่ครอบ `sh -c` → ได้ error `AUTHENTICATION_FAILED` เพราะส่ง literal string `$CLICKHOUSE_PASSWORD` เป็น password ตรงๆ

   วิธีแก้ทั้งสองกรณี: (ก) ครอบทั้งคำสั่งด้วย `sh -c \"...\"` เพื่อให้ `\$CLICKHOUSE_PASSWORD` expand ได้ถูกต้องฝั่ง remote (ตามตัวอย่างในเอกสารนี้ทุกคำสั่ง) และ (ข) สำหรับ `$TODAY` ให้ pre-compute เป็นตัวแปรใน local shell ก่อนเสมอ (ส่วนที่ 1.1) ไม่ต้องพึ่ง remote evaluation เลย เพราะซ้อนอยู่ใน SQL string literal ทำให้ escape ยุ่งยากขึ้นไปอีกชั้นถ้าจะพึ่ง `sh -c` แทน
2. **การลบ S3 `data/` prefix กระทบตาราง `system.*` ภายในของ ClickHouse ด้วย** ไม่ใช่แค่ database ที่ตั้งใจจะลบ เพราะใช้ storage policy เดียวกันทั้ง deployment — ทำให้ ClickHouse crash loop ตอน boot ถ้าไม่ได้ล้าง EFS metadata ให้สอดคล้องกันด้วย
3. **Native backup ไม่ต้องพึ่ง EFS เลย** — ถ้าเข้าใจผิดว่าต้องรันตามลำดับกับ EFS backup จะเสียเวลาคิดเรื่องที่ไม่มีผลจริง สิ่งที่สำคัญคือความถี่ของแต่ละอันแยกกัน ไม่ใช่ลำดับ
4. **`RESTORE DATABASE` อาจ error ถ้า database ปลายทางมีอยู่แล้ว** (แม้จะว่างเปล่า) บาง version ต้องการให้ไม่มี database นั้นอยู่เลย ต้อง `DROP DATABASE` ก่อน
