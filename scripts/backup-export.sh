#!/usr/bin/env bash
# DB 백업 외부 복제용 내보내기. 노트북이 SSH 로 가져간다(pull) — 노트북이 꺼져 있어도
# 실패가 쌓이지 않고, 켜졌을 때 따라잡는다. Pi 에 새 포트를 열거나 MinIO 를 노출하지 않는다.
#
# authorized_keys 의 forced command 로만 실행되는 것을 전제로 한다:
#   command="/home/miginho/project/gitops/scripts/backup-export.sh",restrict ssh-ed25519 AAAA... clog-backup-pull
# → 이 키로는 셸을 못 열고 이 스크립트만 돈다 (SSH_ORIGINAL_COMMAND 는 무시).
#
# 출력: stdout = age 로 암호화한 최신 백업(.sql.gz.age), stderr = "file=<이름> bytes=<크기>" 등 메타데이터
# 실패: 백업이 없거나 / 잘렸거나(dump complete 없음) / 48시간보다 오래됐으면 exit ≠ 0, stdout 비움
#
# 설정: ~/.config/clog-backup/recipient  (노트북에서 만든 age 공개키 한 줄, age1...)
# 기록: ~/.local/state/clog-backup/exports.log (내보낸·ack 받은 기록)
# 수동 테스트: NS=dev BUCKET=clog-backups ./scripts/backup-export.sh > /tmp/x.age
#
# ack: 노트북이 검증·저장을 끝낸 뒤 `ssh ... ack <파일명>` 을 보낸다 (SSH_ORIGINAL_COMMAND).
# 그때만 node-exporter textfile 지표를 갱신 → "노트북에 쓸 수 있는 사본이 생긴 시각"을 감시한다
# (Pi 가 보낸 시각만 보면 노트북 쪽 복호화·저장 실패를 놓친다). 알림: ClogBackupReplicaStale.
#
# keys / ack-keys <번들>: sealed-secrets 마스터 키 외부 백업 (2026-11-09, 감사 H4)
#   이 키가 없으면 디스크 유실 시 Git 의 SealedSecret 을 하나도 못 푼다. 컨트롤러가 30일마다
#   새 키를 만들고 옛 키도 계속 쓰므로 "키 전부"를 매번 내보낸다(수 KB).
#   keys    : 키 전부를 kind: List JSON(클러스터 고유 메타 제거, kubectl apply 로 복구 가능)으로
#             age 암호화해 stdout. stderr = "keys=<개수> bundle=sealed-keys-<개수>-<최신키 UTC>"
#   ack-keys: 노트북 검증 후 지표 갱신 → ClogSealedKeysBackupStale(새 키가 72h 안에 백업 안 됨)
#   평문 키는 디스크에 쓰지 않는다(파이프로만 age 에 전달).
#
# logs / ack-logs <YYYY-MM-DD>: prod 로그 외부 백업 (2026-11-10, 감사 M5)
#   Loki 보존은 7일 → 그 전에 하루(UTC) 단위로 노트북에 사본(90일 보관). Pi 에 파일을 만들지 않고
#   요청 때 Loki 에서 바로 뽑는다(scripts/loki-day-export.py) → 노트북이 며칠 꺼져 있어도 6일 안이면 따라잡음.
#   logs    : 그 날 {namespace="prod"} 전부를 NDJSON → gzip → age 로 stdout.
#             stderr = "logs day=<날짜> lines=<n> raw=<bytes>". Loki 집계와 줄 수가 다르면 실패.
#             허용 범위: 6일 전 ~ 어제 (오늘은 아직 안 끝났고, 7일 전은 보존 삭제와 겹친다)
#   ack-logs: 노트북 검증 후 지표 갱신 → ClogLogBackupStale
#   로그에는 IP·user_id 가 있어 평문은 디스크에 쓰지 않는다(파이프로만 age 에 전달).
#
# tfstate / ack-tfstate <이름>: infra 저장소 Terraform state 외부 백업 (2026-11-12, H5·ADR-095)
#   state 는 Git 에 넣지 않고(웹훅·ping URL 평문) Pi 로컬에만 있다 → 디스크 유실 대비 노트북에 사본.
#   tfstate [stack]: ~/project/infra/<stack>/terraform.tfstate 를 검증(JSON·version 4) 후 age 로 stdout.
#                stack = uptime(기본 — 인자 없는 옛 pull-backup.ps1 호환) | cloudflare (2026-11-14, ADR-096). 그 밖은 거부.
#                stderr = "tfstate name=tfstate-<stack>-<serial>-<sha256 앞 12자> serial=<n> sha256=<64자> bytes=<n>"
#                이름이 내용 해시라 state 가 바뀔 때만 노트북에 새 파일이 생긴다.
#   ack-tfstate: 노트북 검증 후 stack 별 지표 파일 갱신 → ClogTfstateBackupStale·MetricMissing

set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
# forced command 는 .bashrc 를 안 읽어 KUBECONFIG 가 비고, k3s 의 kubectl 은 그때 root 전용
# /etc/rancher/k3s/k3s.yaml 을 읽다 permission denied 가 난다 (2026-11-04 노트북 첫 pull 에서 발생)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
umask 077

NS="${NS:-prod}"
BUCKET="${BUCKET:-clog-backups-prod}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"
RECIPIENT_FILE="${RECIPIENT_FILE:-$HOME/.config/clog-backup/recipient}"   # 테스트 때만 덮어씀(forced command 는 env 를 못 넘김)
LOG_DIR="${LOG_DIR:-$HOME/.local/state/clog-backup}"   # 테스트 때만 덮어씀
RCLONE_IMAGE="rclone/rclone:1.71.1"   # apps/postgres/values.yaml backup.image 와 같은 버전

METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"
TFSTATE_DIR="${TFSTATE_DIR:-$HOME/project/infra}"   # <stack>/terraform.tfstate 의 부모. 테스트 때만 덮어씀
TFSTATE_STACKS="uptime|cloudflare"                  # 허용 stack (임의 경로를 읽지 않게)

log() { echo "backup-export: $*" >&2; }
CLIENT="${SSH_CLIENT:-local}"; CLIENT="${CLIENT%% *}"   # 접속한 IP (수동 실행은 local)

# ── ack <파일명>: 지표만 갱신하고 끝 ──
read -r CMD ARG _ <<< "${SSH_ORIGINAL_COMMAND:-}"
if [ "$CMD" = "ack" ]; then
  # 파일명 형식 + 실제로 내보낸 적 있는 파일만 (임의 문자열이 지표·로그에 들어가지 않게)
  [[ "$ARG" =~ ^[A-Za-z0-9_.-]+-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]] || { log "ack 파일명 형식 오류"; exit 6; }
  grep -q " ns=$NS file=$ARG " "$LOG_DIR/exports.log" 2>/dev/null || { log "내보낸 기록 없는 파일: $ARG"; exit 6; }
  TS=$(echo "$ARG" | grep -oE '[0-9]{8}-[0-9]{6}' | tail -1)
  BTS=$(date -u -d "${TS:0:8} ${TS:9:2}:${TS:11:2}:${TS:13:2}" +%s)
  NOW=$(date -u +%s)
  # node-exporter(uid 65534) 가 읽어야 해서 644, 반쯤 쓴 파일을 읽지 않게 mv 로 교체
  PROM="$METRICS_DIR/clog_backup_replica.prom"
  cat > "$PROM.tmp" <<EOF
# HELP clog_backup_replica_last_success_timestamp_seconds 노트북이 백업 사본을 검증·저장하고 ack 한 시각
# TYPE clog_backup_replica_last_success_timestamp_seconds gauge
clog_backup_replica_last_success_timestamp_seconds{ns="$NS"} $NOW
# HELP clog_backup_replica_backup_timestamp_seconds 노트북에 있는 최신 사본의 백업 생성 시각
# TYPE clog_backup_replica_backup_timestamp_seconds gauge
clog_backup_replica_backup_timestamp_seconds{ns="$NS"} $BTS
EOF
  chmod 644 "$PROM.tmp" && mv "$PROM.tmp" "$PROM"
  echo "$(date -u +%FT%TZ) ack ns=$NS file=$ARG client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "ack ok file=$ARG"
  exit 0
fi

# ── ack-keys <번들>: sealed-secrets 키 백업 지표만 갱신하고 끝 ──
if [ "$CMD" = "ack-keys" ]; then
  [[ "$ARG" =~ ^sealed-keys-([0-9]+)-([0-9]{8})-([0-9]{6})$ ]] || { log "ack-keys 번들 형식 오류"; exit 6; }
  grep -q " keys bundle=$ARG " "$LOG_DIR/exports.log" 2>/dev/null || { log "내보낸 기록 없는 번들: $ARG"; exit 6; }
  COUNT="${BASH_REMATCH[1]}"; D="${BASH_REMATCH[2]}"; T="${BASH_REMATCH[3]}"
  NEWEST=$(date -u -d "${D} ${T:0:2}:${T:2:2}:${T:4:2}" +%s)
  NOW=$(date -u +%s)
  PROM="$METRICS_DIR/clog_sealed_keys_backup.prom"
  cat > "$PROM.tmp" <<EOF
# HELP clog_sealed_keys_backup_last_success_timestamp_seconds 노트북이 sealed-secrets 키 번들을 검증·저장하고 ack 한 시각
# TYPE clog_sealed_keys_backup_last_success_timestamp_seconds gauge
clog_sealed_keys_backup_last_success_timestamp_seconds $NOW
# HELP clog_sealed_keys_backup_newest_key_timestamp_seconds 노트북 번들에 들어 있는 가장 최신 키의 생성 시각
# TYPE clog_sealed_keys_backup_newest_key_timestamp_seconds gauge
clog_sealed_keys_backup_newest_key_timestamp_seconds $NEWEST
# HELP clog_sealed_keys_backup_key_count 노트북 번들에 들어 있는 키 개수
# TYPE clog_sealed_keys_backup_key_count gauge
clog_sealed_keys_backup_key_count $COUNT
EOF
  chmod 644 "$PROM.tmp" && mv "$PROM.tmp" "$PROM"
  echo "$(date -u +%FT%TZ) ack-keys bundle=$ARG client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "ack-keys ok bundle=$ARG"
  exit 0
fi

# ── ack-logs <날짜>: 로그 백업 지표만 갱신하고 끝 ──
if [ "$CMD" = "ack-logs" ]; then
  [[ "$ARG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { log "ack-logs 날짜 형식 오류"; exit 6; }
  grep -q " logs day=$ARG " "$LOG_DIR/exports.log" 2>/dev/null || { log "내보낸 기록 없는 날짜: $ARG"; exit 6; }
  DAY_TS=$(date -u -d "$ARG" +%s)
  NOW=$(date -u +%s)
  PROM="$METRICS_DIR/clog_log_backup.prom"
  # 노트북이 밀린 날을 옛날 것부터 채우므로 "가장 최근 날" 은 기존 값과 비교해 큰 쪽을 유지
  PREV=$(awk '/^clog_log_backup_newest_day_timestamp_seconds /{print $2}' "$PROM" 2>/dev/null || true)
  [ -n "$PREV" ] && [ "$PREV" -gt "$DAY_TS" ] && DAY_TS=$PREV
  cat > "$PROM.tmp" <<EOF
# HELP clog_log_backup_last_success_timestamp_seconds 노트북이 prod 로그 하루치를 검증·저장하고 ack 한 시각
# TYPE clog_log_backup_last_success_timestamp_seconds gauge
clog_log_backup_last_success_timestamp_seconds $NOW
# HELP clog_log_backup_newest_day_timestamp_seconds 노트북에 있는 가장 최근 로그 날짜(UTC 00:00)
# TYPE clog_log_backup_newest_day_timestamp_seconds gauge
clog_log_backup_newest_day_timestamp_seconds $DAY_TS
EOF
  chmod 644 "$PROM.tmp" && mv "$PROM.tmp" "$PROM"
  echo "$(date -u +%FT%TZ) ack-logs day=$ARG client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "ack-logs ok day=$ARG"
  exit 0
fi

# ── ack-tfstate <이름>: Terraform state 백업 지표만 갱신하고 끝 ──
if [ "$CMD" = "ack-tfstate" ]; then
  [[ "$ARG" =~ ^tfstate-($TFSTATE_STACKS)-([0-9]+)-[0-9a-f]{12}$ ]] || { log "ack-tfstate 이름 형식 오류"; exit 6; }
  grep -q " tfstate name=$ARG " "$LOG_DIR/exports.log" 2>/dev/null || { log "내보낸 기록 없는 state: $ARG"; exit 6; }
  STACK="${BASH_REMATCH[1]}"; SERIAL="${BASH_REMATCH[2]}"
  NOW=$(date -u +%s)
  # stack 마다 파일 하나 — 한 stack 의 ack 가 다른 stack 의 지표를 지우지 않게
  PROM="$METRICS_DIR/clog_tfstate_backup_$STACK.prom"
  cat > "$PROM.tmp" <<EOF
# HELP clog_tfstate_backup_last_success_timestamp_seconds 노트북이 Terraform state 사본을 검증·저장하고 ack 한 시각
# TYPE clog_tfstate_backup_last_success_timestamp_seconds gauge
clog_tfstate_backup_last_success_timestamp_seconds{stack="$STACK"} $NOW
# HELP clog_tfstate_backup_serial 노트북에 있는 최신 state 의 serial
# TYPE clog_tfstate_backup_serial gauge
clog_tfstate_backup_serial{stack="$STACK"} $SERIAL
EOF
  chmod 644 "$PROM.tmp" && mv "$PROM.tmp" "$PROM"
  # 옛 단일 파일(11-12, uptime 만)은 같은 시리즈를 중복 노출해 node-exporter 수집 오류가 난다 → 새 파일을 쓴 뒤 제거
  [ "$STACK" = "uptime" ] && rm -f "$METRICS_DIR/clog_tfstate_backup.prom"
  echo "$(date -u +%FT%TZ) ack-tfstate name=$ARG client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "ack-tfstate ok name=$ARG"
  exit 0
fi

[ -s "$RECIPIENT_FILE" ] || { log "공개키 없음: $RECIPIENT_FILE"; exit 2; }

# ── tfstate: Terraform state 를 검증해 암호화해 내보내기 ──
if [ "$CMD" = "tfstate" ]; then
  STACK="${ARG:-uptime}"
  [[ "$STACK" =~ ^($TFSTATE_STACKS)$ ]] || { log "tfstate stack 오류: $STACK"; exit 9; }
  TFSTATE_FILE="$TFSTATE_DIR/$STACK/terraform.tfstate"
  [ -s "$TFSTATE_FILE" ] || { log "state 없음: $TFSTATE_FILE"; exit 9; }
  # 쓰는 도중(apply 중)의 반쪽 파일을 내보내지 않게 JSON·version·serial 을 확인
  SERIAL=$(python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
if s.get("version") != 4 or not s.get("lineage") or not isinstance(s.get("serial"), int):
    sys.exit("state 형식 오류")
print(s["serial"])' "$TFSTATE_FILE") || { log "state 검증 실패: $TFSTATE_FILE"; exit 9; }
  SHA=$(sha256sum "$TFSTATE_FILE" | cut -d' ' -f1)
  BYTES=$(stat -c %s "$TFSTATE_FILE")
  NAME="tfstate-$STACK-$SERIAL-${SHA:0:12}"
  age -R "$RECIPIENT_FILE" < "$TFSTATE_FILE"
  mkdir -p "$LOG_DIR"
  echo "$(date -u +%FT%TZ) tfstate name=$NAME serial=$SERIAL bytes=$BYTES client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "tfstate name=$NAME serial=$SERIAL sha256=$SHA bytes=$BYTES"
  exit 0
fi

# ── logs <날짜>: 그 날 prod 로그를 암호화해 내보내기 ──
if [ "$CMD" = "logs" ]; then
  [[ "$ARG" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -u -d "$ARG" +%F >/dev/null 2>&1 || { log "logs 날짜 형식 오류"; exit 7; }
  [ "$(date -u -d "$ARG" +%F)" = "$ARG" ] || { log "logs 날짜 형식 오류"; exit 7; }
  OLDEST=$(date -u -d '6 days ago' +%F); NEWEST=$(date -u -d yesterday +%F)
  { [[ ! "$ARG" < "$OLDEST" ]] && [[ ! "$ARG" > "$NEWEST" ]]; } || { log "범위 밖 날짜 $ARG (허용 $OLDEST ~ $NEWEST)"; exit 7; }
  LOKI_IP=$(kubectl -n monitoring get svc monitoring-loki -o jsonpath='{.spec.clusterIP}')
  [ -n "$LOKI_IP" ] || { log "Loki Service 없음"; exit 8; }
  META=$(mktemp); trap 'rm -f "$META"' EXIT   # 메타데이터(줄 수)만 — 로그 본문은 파이프로만
  python3 -I "$(dirname "$0")/loki-day-export.py" "http://$LOKI_IP:3100" "$ARG" '{namespace="prod"}' 2>"$META" \
    | gzip -9 | age -R "$RECIPIENT_FILE" \
    || { log "로그 내보내기 실패 day=$ARG: $(tr '\n' ' ' < "$META" | cut -c1-200)"; exit 8; }
  STAT=$(grep -oE 'lines=[0-9]+ raw=[0-9]+' "$META")
  mkdir -p "$LOG_DIR"
  echo "$(date -u +%FT%TZ) logs day=$ARG $STAT client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "logs day=$ARG $STAT"
  exit 0
fi

# ── keys: sealed-secrets 마스터 키 전부를 암호화해 내보내기 ──
if [ "$CMD" = "keys" ]; then
  # 평문은 변수(메모리)에만 — 디스크·로그에 남기지 않는다
  BUNDLE_JSON=$(kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o json \
    | python3 -I -c '
import json, sys
src = json.load(sys.stdin)["items"]
if not src: sys.exit("키 없음")
items = []
for s in src:
    m = s["metadata"]
    if not s.get("data", {}).get("tls.key") or not s.get("data", {}).get("tls.crt"):
        sys.exit("tls.key/tls.crt 없는 키: " + m["name"])
    items.append({"apiVersion": "v1", "kind": "Secret", "type": s["type"],
                  "metadata": {"name": m["name"], "namespace": m["namespace"],
                               "labels": m.get("labels", {}),
                               "annotations": {"clog/original-creationTimestamp": m["creationTimestamp"]}},
                  "data": {"tls.crt": s["data"]["tls.crt"], "tls.key": s["data"]["tls.key"]}})
items.sort(key=lambda i: i["metadata"]["annotations"]["clog/original-creationTimestamp"])
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))')
  COUNT=$(printf '%s' "$BUNDLE_JSON" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')
  NEWEST_ISO=$(printf '%s' "$BUNDLE_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["items"][-1]["metadata"]["annotations"]["clog/original-creationTimestamp"])')
  BUNDLE="sealed-keys-$COUNT-$(date -u -d "$NEWEST_ISO" +%Y%m%d-%H%M%S)"
  # here-string(<<<)은 64KB 를 넘으면 bash 가 임시 파일을 쓰므로 항상 파이프로
  printf '%s' "$BUNDLE_JSON" | age -R "$RECIPIENT_FILE"
  unset BUNDLE_JSON
  mkdir -p "$LOG_DIR"
  echo "$(date -u +%FT%TZ) keys bundle=$BUNDLE count=$COUNT client=$CLIENT" >> "$LOG_DIR/exports.log"
  log "keys=$COUNT bundle=$BUNDLE"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 백업 CronJob 과 같은 Secret 으로 rclone 을 띄우는 일회용 Pod (Secret 값은 Pod 안에만 존재)
rclone_pod() {
  local ov
  ov=$(cat <<EOF
{"spec":{"restartPolicy":"Never","containers":[{"name":"r","image":"$RCLONE_IMAGE","imagePullPolicy":"IfNotPresent","args":$1,
"resources":{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}},
"env":[{"name":"RCLONE_CONFIG","value":"/dev/null"},{"name":"RCLONE_CONFIG_BACKUP_TYPE","value":"s3"},{"name":"RCLONE_CONFIG_BACKUP_PROVIDER","value":"Minio"},{"name":"RCLONE_CONFIG_BACKUP_ENDPOINT","value":"http://minio.storage.svc.cluster.local:9000"},
{"name":"RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_ACCESS_KEY"}}},
{"name":"RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"minio-clog-credentials","key":"MINIO_SECRET_KEY"}}}]}]}}
EOF
)
  kubectl run "backup-export-$(date +%s)-$RANDOM" -n "$NS" --attach --rm --quiet --restart=Never \
    --image="$RCLONE_IMAGE" --overrides="$ov" </dev/null
}

# 1) 최신 파일 이름 (파일명에 UTC 시각이 들어 있어 이름순 = 시간순)
FILE=$(rclone_pod "[\"lsf\",\"backup:$BUCKET/\",\"--include\",\"*.sql.gz\"]" | sort | tail -1)
[ -n "$FILE" ] || { log "버킷 $BUCKET 에 백업 없음"; exit 3; }

# 2) 신선도: 파일명의 YYYYMMDD-HHMMSS(UTC)
TS=$(echo "$FILE" | grep -oE '[0-9]{8}-[0-9]{6}' | tail -1)
AGE_H=$(( ( $(date -u +%s) - $(date -u -d "${TS:0:8} ${TS:9:2}:${TS:11:2}:${TS:13:2}" +%s) ) / 3600 ))
[ "$AGE_H" -le "$MAX_AGE_HOURS" ] || { log "최신 백업이 ${AGE_H}시간 전 ($FILE) — CronJob 확인 필요"; exit 4; }

# 3) 가져와서 검증 (잘린 파일은 내보내지 않는다)
rclone_pod "[\"cat\",\"backup:$BUCKET/$FILE\"]" > "$TMP/$FILE"
gzip -t "$TMP/$FILE"                                     || { log "gzip 손상: $FILE"; exit 5; }
zcat "$TMP/$FILE" | grep -q 'PostgreSQL database dump complete' || { log "끝 표시 없음(잘림): $FILE"; exit 5; }

# 4) 암호화해서 stdout 으로 (평문은 Pi 의 임시 디렉터리에만 잠깐 있다가 trap 으로 삭제)
age -R "$RECIPIENT_FILE" < "$TMP/$FILE" > "$TMP/out.age"
BYTES=$(stat -c %s "$TMP/$FILE")
cat "$TMP/out.age"

mkdir -p "$LOG_DIR"
echo "$(date -u +%FT%TZ) ns=$NS file=$FILE bytes=$BYTES age_h=$AGE_H client=$CLIENT" >> "$LOG_DIR/exports.log"
log "file=$FILE bytes=$BYTES age_h=$AGE_H"
