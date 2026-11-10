# 🛟 PostgreSQL 백업 복구 Runbook

> 백업이 "있다"가 아니라 "복구된다"를 확인하는 절차.
> 1~4 는 2026-11-04, 5(클러스터 DB 교체 복구)는 2026-11-10 dev 리허설에서 실제로 실행·검증했다 (감사 M11).

## 백업 사양

| 항목 | 값 |
|---|---|
| 방식 | CronJob `postgres-<env>-backup`: `pg_dump \| gzip` (평문 SQL) → rclone → MinIO |
| 주기 | 매일 03:00 KST (UTC 18:00) |
| 위치 | MinIO `minio.storage.svc.cluster.local:9000` — prod `clog-backups-prod`, dev `clog-backups` |
| 보관 | 7일 (`rclone delete --min-age 7d`) |
| 파일명 | `postgres-prod-clog_dev-YYYYMMDD-HHMMSS.sql.gz` (prod DB 이름도 `clog_dev`) |
| RPO | 최대 24시간 |
| 실패 감지 | `set -euo pipefail` → pg_dump 실패 시 Job 실패 → `KubeJobFailed` 알림 |
| 외부 복제 | 노트북(Windows)이 매일 09:00·로그온 시 pull, age 암호문으로 30일(최소 7개) 보관 — [아래](#외부-복제-노트북) |

### ⚠️ 알려진 한계
- 클러스터 안 백업은 DB 와 같은 노드·같은 디스크에 있다 → 노드를 잃으면 **노트북 사본이 유일한 백업**.
- 노트북 사본은 노트북이 켜져(로그인 상태) 있어야 갱신된다 → 노트북이 ack 한 시각을 지표로 감시, 72h 끊기면 `ClogBackupReplicaStale` (Discord infra).
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

OV='{"spec":{"restartPolicy":"Never","containers":[{"name":"r","image":"rclone/rclone:1.71.1","imagePullPolicy":"IfNotPresent","command":["sleep","600"],
"resources":{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}},
"env":[{"name":"RCLONE_CONFIG","value":"/dev/null"},{"name":"RCLONE_CONFIG_BACKUP_TYPE","value":"s3"},{"name":"RCLONE_CONFIG_BACKUP_PROVIDER","value":"Minio"},{"name":"RCLONE_CONFIG_BACKUP_ENDPOINT","value":"http://minio.storage.svc.cluster.local:9000"},
{"name":"RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_ACCESS_KEY"}}},
{"name":"RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_SECRET_KEY"}}}]}]}}'

# kubectl run -i/--attach 의 stdout 은 앞부분 바이트가 유실될 수 있다(2026-11-10 M4 스냅샷에서 실제 발생)
# → 대기 Pod 를 띄우고 exec 로 받는다. 받은 크기를 lsl 크기와 대조할 것.
kubectl run backup-fetch -n $NS --restart=Never --image=rclone/rclone:1.71.1 --overrides="$OV" >/dev/null
kubectl wait -n $NS --for=condition=Ready pod/backup-fetch --timeout=60s
kubectl exec -n $NS backup-fetch -- rclone lsl backup:$BUCKET/$FILE        # 원본 크기
kubectl exec -n $NS backup-fetch -- rclone cat backup:$BUCKET/$FILE > $D/$FILE
kubectl delete pod -n $NS backup-fetch --wait=false
ls -l $D/$FILE                                                             # 크기 일치 확인
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

## 5. 클러스터 DB 교체 복구 (2026-11-10 dev 리허설 검증)

> 원칙: 현재 DB 를 덮어쓰지 않는다. **현재 상태를 먼저 덤프**하고, 새 DB 에 복구·검증한 뒤 **이름을 바꿔 끼운다.**
> 옛 DB 는 `clog_broken` 으로 남겨 되돌릴 수 있게 한다.
> 리허설 실측(dev): 3~6 명령 57초 + 앱 Ready 13초 → **이어서 실행하면 중단 약 1분 30초.**

### 환경별 이름

| | dev | prod |
|---|---|---|
| NS / DB Pod | `dev` / `postgres-0` | `prod` / `postgres-prod-0` |
| API · worker | `clog-dev` · `clog-dev-worker` | `clog-prod` · `clog-prod-worker` |
| CronJob (DB 쓰기·백업) | `clog-dev-media-reconcile` · `clog-dev-media-stale-reconcile` · `postgres-backup` | `clog-prod-media-reconcile` · `clog-prod-media-stale-reconcile` · `postgres-prod-backup` |
| ArgoCD | `clog-dev` auto-sync+selfHeal → **끄기 필요** | `clog-prod` 수동 sync → 끌 필요 없음 |
| 백업 버킷 | `clog-backups` | `clog-backups-prod` |

### ⚠️ 리허설에서 드러난 함정

1. **selfHeal 이 replicas 를 되돌린다** — `clog-dev` 를 끄려면 그 Application 을 관리하는 `root-app` 의 automated 도 먼저 꺼야 한다
   (아니면 root-app 이 clog-dev 정의를 Git 값으로 되돌림). CronJob `suspend` 는 차트에 없는 필드라 selfHeal 앱에서도 유지된다(dev 6분간 확인).
2. **CronJob 도 멈춰야 한다** — `media-stale-reconcile` 은 15분마다 DB 를 고친다. 백업 CronJob 도 복구 중엔 멈춘다.
3. **`media-reconcile` 은 복구 후 미디어를 영구 삭제할 수 있다** — DB 가 참조하지 않는 MinIO 객체 중 24h 지난 것을 지운다.
   백업 시점 이후 올라온 게시물의 원본은 복구된 DB 에 없으므로 **다음 18:30 UTC 실행에서 삭제**된다(수동 복구 기회 상실).
   → 재개 전 dry-run 으로 orphan 수를 보고, 0 이 아니면 suspend 를 유지한 채 객체를 살펴본다.
4. **`clog` 는 CREATEDB 권한이 없다**(최소 권한, 유지) → DB 생성·이름 변경은 Pod 안 로컬 소켓의 `postgres` 슈퍼유저로,
   데이터 복구는 `clog` 로 (객체 소유자 `clog` 유지).
5. **이름 변경 2회는 한 트랜잭션으로** — 두 번째가 실패하면 첫 번째도 롤백된다(임시 DB 로 확인). 따로 실행하면 `clog_dev` 가 없는 상태가 생길 수 있다.
6. 헬스 경로는 `/health/ready` (`/api/...` 아님). 계획된 4분 중단 동안 장애 알림은 오지 않았다.

### 절차

```bash
NS=dev; PG=postgres-0; API=clog-dev; WORKER=clog-dev-worker
CJ="clog-dev-media-reconcile clog-dev-media-stale-reconcile postgres-backup"
SU(){ kubectl exec -i -n $NS $PG -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
C(){ kubectl exec -n $NS $PG -- psql -U clog -d "$1" -tAF $'\t' -c "$2"; }

# 0) 중단 전 준비 — 2·3 절로 백업 파일을 받고 검증해 둔다 (중단 시간에서 빠진다)

# 1) (dev 만) 자동 복원 끄기 — 원래 값 저장 후 root-app 먼저
for a in root-app clog-dev; do kubectl -n argocd get application $a -o jsonpath='{.spec.syncPolicy}' > $D/syncpolicy-$a.json; done
kubectl -n argocd patch application root-app --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application clog-dev --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 2) 쓰기 중지 (여기부터 중단)
kubectl scale deploy -n $NS $API $WORKER --replicas=0
for c in $CJ; do kubectl patch cronjob -n $NS $c -p '{"spec":{"suspend":true}}'; done
kubectl get deploy -n $NS $API $WORKER; kubectl get jobs -n $NS | grep -v Complete    # 0/0, 실행 중 Job 없음
SU -tAc "select count(*) from pg_stat_activity where datname='clog_dev'"            # 0 이어야 함

# 3) 현재 DB 안전 덤프 (개인정보 — $D 는 700)
set -o pipefail
kubectl exec -n $NS $PG -- pg_dump -U clog -d clog_dev | gzip > $D/before-restore.sql.gz
gzip -t $D/before-restore.sql.gz && zcat $D/before-restore.sql.gz | grep -c 'PostgreSQL database dump complete'

# 4) 새 DB 에 복구 → 4 절 검증 쿼리 (C clog_restore "...") 로 행 수·alembic·FK 확인
SU -tAc "create database clog_restore owner clog"
zcat $F | kubectl exec -i -n $NS $PG -- psql -U clog -d clog_restore -v ON_ERROR_STOP=1 -q

# 5) 바꿔 끼우기 — 접속 0 확인 후 한 트랜잭션
SU -tAc "select count(*) from pg_stat_activity where datname in ('clog_dev','clog_restore')"
printf 'begin;\nalter database clog_dev rename to clog_broken;\nalter database clog_restore rename to clog_dev;\ncommit;\n' | SU
SU -tAc "select oid, datname from pg_database where datname like 'clog%'"          # clog_dev 의 OID 가 바뀌었는지

# 6) 앱 복귀 (여기까지 중단)
kubectl scale deploy -n $NS $API $WORKER --replicas=<원래 값>                       # prod API 2, worker 1
kubectl rollout status -n $NS deploy/$API
kubectl exec -n $NS deploy/$API -- python -c "import urllib.request as u;print(u.urlopen('http://127.0.0.1:8000/health/ready').read().decode())"

# 7) CronJob 재개 — media-reconcile 은 dry-run 으로 orphan 0 확인 후
kubectl exec -n $NS deploy/$API -- python -m app.scripts.media_reconcile | grep media_reconcile_scan
for c in $CJ; do kubectl patch cronjob -n $NS $c -p '{"spec":{"suspend":false}}'; done

# 8) (dev 만) 자동 복원 원복 → 전 앱 Synced/Healthy
kubectl -n argocd patch application clog-dev --type merge -p "{\"spec\":{\"syncPolicy\":$(cat $D/syncpolicy-clog-dev.json)}}"
kubectl -n argocd patch application root-app --type merge -p "{\"spec\":{\"syncPolicy\":$(cat $D/syncpolicy-root-app.json)}}"
```

**되돌리기** (복구본이 잘못됐을 때): 2) 로 다시 멈춘 뒤 한 트랜잭션으로
`clog_dev → clog_bad`, `clog_broken → clog_dev` → 6)·7).
**정리**: 하루 이상 문제없으면 `drop database clog_broken` (확인 후), `rm -r $D`.

## 외부 복제 (노트북)

노트북이 Pi 에서 가져가는 pull 방식 — 노트북이 꺼져 있던 날은 켜질 때 따라잡고, Pi 에 새 포트를 열거나 MinIO 를 노출하지 않는다.

```
[노트북 작업 스케줄러 clog-backup-pull: 매일 09:00 + 로그온 3분 뒤, 놓친 실행은 켜지면 즉시]
  scripts/pull-backup.ps1
   └ ssh -i pull_ed25519 miginho@100.96.195.103 (Tailscale)
        → Pi authorized_keys: command="scripts/backup-export.sh",restrict,from="LAN,Tailscale"
          1) rclone 일회용 Pod 로 최신 prod 백업  2) 48h 신선도·gzip·dump complete 검사
          3) age 공개키로 암호화 → stdout       4) exports.log 기록
   ← .sql.gz.age
  복호화 → 크기 일치 → gzip 해제 → dump complete 확인 → 암호문만 backups\ 에 저장 (평문은 임시 파일 후 삭제)
  └ ssh ... ack <파일명>  (저장 성공·이미 있음 모두)
        → Pi: /var/lib/node_exporter/textfile_collector/clog_backup_replica.prom 갱신
        → node-exporter textfile collector → Prometheus
          ClogBackupReplicaStale (ack 72h 초과) / ClogBackupReplicaMetricMissing (지표 1h 없음)
```

| 항목 | 위치 |
|---|---|
| Pi 내보내기 | `scripts/backup-export.sh`, 공개키 `~/.config/clog-backup/recipient`, 기록 `~/.local/state/clog-backup/exports.log` |
| 노트북 | `%USERPROFILE%\clog-backup\` — `pull-backup.ps1`, `register-pull-task.ps1`, `backups\`, `pull.log` |
| 키 | `keys\pull_ed25519` (이 스크립트만 실행 가능한 키), `keys\age.key` (**비밀키 — 사본을 노트북 밖에도 보관, 잃으면 복제본 복구 불가**) |

### 노트북 사본으로 복구할 때

```powershell
cd $env:USERPROFILE\clog-backup
age -d -i keys\age.key -o restore.sql.gz backups\<파일>.sql.gz.age
scp restore.sql.gz miginho@<Pi>:/tmp/     # 이후 2~5 절 그대로 (F=/tmp/restore.sql.gz)
Remove-Item restore.sql.gz                # 평문 삭제
```

## 리허설 기록

| 날짜 | 백업 파일 | 결과 | 복구 시간 | 비고 |
|---|---|---|---|---|
| 2026-11-04 | prod 2026-11-03 03:00 KST (34.9KB) | ✅ 오류 0, 10개 테이블 행 수 일치(361행), alembic `8e9240acd321` = head, 인덱스 36·FK 14 유효 | 컨테이너 준비 2.0s + 복구 0.3s | 리허설 중 `pipefail` 누락 발견·수정 (pg_dump 실패해도 20B 빈 백업이 Complete 로 업로드되던 문제) |
| 2026-11-04 | 신선도 감시 (ack) | ✅ 노트북 ack → .prom → Prometheus 수집, Missing pending→inactive. promtool test rules 3 시나리오 통과 | - | 지표 파일은 umask 077 이면 node-exporter(uid 65534)가 못 읽어 644 명시 |
| 2026-11-04 | 노트북 외부 복제 첫 pull (같은 파일) | ✅ Pi → age → Tailscale → 노트북 복호화 34,892B 일치, 스케줄러 숨김 실행 LastTaskResult 0 | 내보내기 약 6s | forced command 환경엔 `.bashrc` 가 없어 KUBECONFIG 미설정 → k3s kubectl 이 root 전용 k3s.yaml 을 읽다 실패 → 스크립트에서 명시 |
| 2026-11-10 | dev `postgres-clog_dev-20261110-063918` (17.8KB) — 5 절 클러스터 DB 교체 | ✅ 10개 테이블 169행 = COPY = 교체 전 기준값, alembic `8e9240acd321`, 인덱스 36·FK 14(NOT VALID 0), `clog_dev` OID 16385→32811, `/health/ready` 200, reconcile dry-run orphan 0, ArgoCD 14개 Synced | 복구 0.4s, 3~6 명령 57s, 앱 Ready 13s (승인 대기 포함 전체 중단 4m18s) | 발견: `clog` CREATEDB 없음 → postgres 슈퍼유저로 생성·이름 변경 / selfHeal 이 replicas 복원(root-app 까지 꺼야) / CronJob 누락 / media-reconcile 이 백업 이후 미디어 삭제 위험 / rename 2회 트랜잭션화 / `kubectl run -i` 바이트 유실 → exec 방식 |
