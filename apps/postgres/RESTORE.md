# 🛟 PostgreSQL 백업 복구 Runbook

> 백업이 "있다"가 아니라 "복구된다"를 확인하는 절차.
> 1~4 는 2026-11-04 리허설에서 실제로 실행·검증했다. 5(실제 prod 복구)는 **아직 리허설하지 않았다.**

## 백업 사양

| 항목 | 값 |
|---|---|
| 방식 | CronJob `postgres-<env>-backup`: `pg_dump \| gzip` (평문 SQL) → rclone → MinIO |
| 주기 | 매일 03:00 KST (UTC 18:00) |
| 위치 | MinIO `minio.dev.svc.cluster.local:9000` — prod `clog-backups-prod`, dev `clog-backups` |
| 보관 | 7일 (`rclone delete --min-age 7d`) |
| 파일명 | `postgres-prod-clog_dev-YYYYMMDD-HHMMSS.sql.gz` (prod DB 이름도 `clog_dev`) |
| RPO | 최대 24시간 |
| 실패 감지 | `set -euo pipefail` → pg_dump 실패 시 Job 실패 → `KubeJobFailed` 알림 |

### ⚠️ 알려진 한계
- **백업이 DB 와 같은 노드·같은 디스크에 있다.** NVMe/노드를 잃으면 DB 와 백업이 함께 사라진다 (외부 복제 미구성).
- PITR 불가 (WAL 아카이빙 없음) — 마지막 03:00 시점으로만 되돌릴 수 있다.

## 1. 백업 목록 확인

마지막 백업 Job 로그에 버킷 목록(`rclone ls`)이 찍힌다.

```bash
NS=prod
J=$(kubectl get jobs -n $NS -l app.kubernetes.io/component=backup \
    --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl logs -n $NS $J -c pg-dump    # dumped ... (크기)
kubectl logs -n $NS $J -c upload     # 버킷 파일 목록
```

## 2. 백업 파일 가져오기

백업 Job 과 같은 Secret 을 쓰는 rclone 일회용 Pod 로 `rclone cat` → 로컬 파일.
Secret 값은 Pod 환경변수로만 들어가고 화면·로컬에 남지 않는다.
**덤프에는 개인정보(이메일·비밀번호 해시)가 있다 → 권한 700/600, 끝나면 삭제.**

```bash
NS=prod; BUCKET=clog-backups-prod
FILE=postgres-prod-clog_dev-20261103-180001.sql.gz      # 1 에서 고른 파일
D=$(mktemp -d); chmod 700 $D; umask 077

OV='{"spec":{"restartPolicy":"Never","containers":[{"name":"r","image":"rclone/rclone:1.71.1","imagePullPolicy":"IfNotPresent","args":["cat","backup:'$BUCKET'/'$FILE'"],
"resources":{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}},
"env":[{"name":"RCLONE_CONFIG","value":"/dev/null"},{"name":"RCLONE_CONFIG_BACKUP_TYPE","value":"s3"},{"name":"RCLONE_CONFIG_BACKUP_PROVIDER","value":"Minio"},{"name":"RCLONE_CONFIG_BACKUP_ENDPOINT","value":"http://minio.dev.svc.cluster.local:9000"},
{"name":"RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_ACCESS_KEY"}}},
{"name":"RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_SECRET_KEY"}}}]}]}}'

kubectl run backup-fetch -n $NS -i --rm --quiet --restart=Never \
  --image=rclone/rclone:1.71.1 --overrides="$OV" > $D/$FILE
```

## 3. 파일 검증 (복구 전)

```bash
F=$D/$FILE
gzip -t $F && echo "gzip OK"
zcat $F | grep -q 'PostgreSQL database dump complete' && echo "끝까지 덤프됨"   # 없으면 잘린 파일
zcat $F | grep -m2 -E '^-- Dumped (from|by)'                                 # 서버/pg_dump 버전
# 테이블별 COPY 행 수 (복구 후 비교용)
zcat $F | awk '/^COPY .* FROM stdin;$/{t=$2;n=0;f=1;next} f&&/^\\\.$/{print n"\t"t;f=0;next} f{n++}' \
  | sort -k2 > $D/copy_counts.tsv
```

## 4. 리허설 복구 (클러스터 밖 임시 컨테이너)

덤프의 소유자 역할이 `clog` 라 같은 이름으로 띄운다. 같은 Pi 에서 돌므로 메모리 상한을 건다.

```bash
docker run -d --name clog-restore-rehearsal --memory=256m -p 127.0.0.1:55432:5432 \
  -e POSTGRES_USER=clog -e POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64)" \
  -e POSTGRES_DB=clog_restore postgres:16-alpine
until docker exec clog-restore-rehearsal psql -U clog -d clog_restore -tAc 'select 1' >/dev/null 2>&1; do sleep 0.2; done

time (zcat $F | docker exec -i clog-restore-rehearsal psql -U clog -d clog_restore -v ON_ERROR_STOP=1 -q)
```

### 검증 쿼리

```bash
P(){ docker exec clog-restore-rehearsal psql -U clog -d clog_restore -tAF $'\t' -c "$1"; }

# 1) 테이블별 행 수 = 덤프 COPY 행 수
P "select format('%s.%s',schemaname,relname) from pg_stat_user_tables order by 1" \
  | while read t; do echo -e "$(P "select count(*) from $t")\t$t"; done | sort -k2 > $D/restored.tsv
diff $D/copy_counts.tsv $D/restored.tsv && echo "행 수 일치"

# 2) 마이그레이션 버전 = clog-backend 의 `uv run alembic heads`
P "select version_num from alembic_version"

# 3) 스키마 객체 / FK 유효성 (NOT VALID 0 이어야 함)
P "select count(*) from pg_indexes where schemaname='public'"
P "select contype, count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace where nspname='public' group by 1"
P "select count(*) from pg_constraint where contype='f' and not convalidated"

# 4) 앱 규칙대로 조회 (soft delete 필터)
P "select count(*) from users where deleted_at is null"
P "select max(created_at) from climbing_logs"     # 데이터가 어느 시점까지 있는지
```

### 정리 (필수 — 개인정보)

```bash
docker rm -f clog-restore-rehearsal
rm -r $D
```

## 5. 실제 prod 복구 (⚠️ 미리허설)

> 아래는 계획이다. 실제 사용 전 **dev 에서 먼저 리허설**하고 이 절을 검증된 절차로 고칠 것.
> 원칙: 현재 DB 를 덮어쓰기 전에 **현재 상태를 먼저 덤프**하고, 새 DB 에 복구해 검증한 뒤 바꿔 끼운다.

1. 쓰기 중지: `kubectl scale deploy -n prod clog-prod clog-prod-worker --replicas=0`
   (clog-prod 앱은 수동 sync 라 replicas 가 되돌아가지 않고 OutOfSync 로만 표시됨 — 2026-11-04 확인.
   postgres-prod 는 selfHeal 이지만 DB 이름 변경은 매니페스트 밖이라 영향 없음)
2. 현재 DB 안전 덤프: `kubectl exec -n prod postgres-prod-0 -- pg_dump -U clog -d clog_dev | gzip > before-restore.sql.gz`
3. 새 DB 에 복구: `createdb -U clog clog_restore` → `zcat $F | kubectl exec -i -n prod postgres-prod-0 -- psql -U clog -d clog_restore -v ON_ERROR_STOP=1`
4. 4 의 검증 쿼리로 확인
5. 바꿔 끼우기: `ALTER DATABASE clog_dev RENAME TO clog_broken; ALTER DATABASE clog_restore RENAME TO clog_dev;` (접속 0 상태에서)
6. 앱 복귀: replicas 원복 → auto-sync 재개 → `/api/health/ready` 확인

## 리허설 기록

| 날짜 | 백업 파일 | 결과 | 복구 시간 | 비고 |
|---|---|---|---|---|
| 2026-11-04 | prod 2026-11-03 03:00 KST (34.9KB) | ✅ 오류 0, 10개 테이블 행 수 일치(361행), alembic `8e9240acd321` = head, 인덱스 36·FK 14 유효 | 컨테이너 준비 2.0s + 복구 0.3s | 리허설 중 `pipefail` 누락 발견·수정 (pg_dump 실패해도 20B 빈 백업이 Complete 로 업로드되던 문제) |
