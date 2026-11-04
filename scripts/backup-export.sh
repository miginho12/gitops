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
# 기록: ~/.local/state/clog-backup/exports.log (내보낸 시각 — 복제 신선도 확인용)
# 수동 테스트: NS=dev BUCKET=clog-backups ./scripts/backup-export.sh > /tmp/x.age

set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
# forced command 는 .bashrc 를 안 읽어 KUBECONFIG 가 비고, k3s 의 kubectl 은 그때 root 전용
# /etc/rancher/k3s/k3s.yaml 을 읽다 permission denied 가 난다 (2026-11-04 노트북 첫 pull 에서 발생)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
umask 077

NS="${NS:-prod}"
BUCKET="${BUCKET:-clog-backups-prod}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"
RECIPIENT_FILE="$HOME/.config/clog-backup/recipient"
LOG_DIR="$HOME/.local/state/clog-backup"
RCLONE_IMAGE="rclone/rclone:1.71.1"   # apps/postgres/values.yaml backup.image 와 같은 버전

log() { echo "backup-export: $*" >&2; }

[ -s "$RECIPIENT_FILE" ] || { log "공개키 없음: $RECIPIENT_FILE"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 백업 CronJob 과 같은 Secret 으로 rclone 을 띄우는 일회용 Pod (Secret 값은 Pod 안에만 존재)
rclone_pod() {
  local ov
  ov=$(cat <<EOF
{"spec":{"restartPolicy":"Never","containers":[{"name":"r","image":"$RCLONE_IMAGE","imagePullPolicy":"IfNotPresent","args":$1,
"resources":{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}},
"env":[{"name":"RCLONE_CONFIG","value":"/dev/null"},{"name":"RCLONE_CONFIG_BACKUP_TYPE","value":"s3"},{"name":"RCLONE_CONFIG_BACKUP_PROVIDER","value":"Minio"},{"name":"RCLONE_CONFIG_BACKUP_ENDPOINT","value":"http://minio.dev.svc.cluster.local:9000"},
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
echo "$(date -u +%FT%TZ) ns=$NS file=$FILE bytes=$BYTES age_h=$AGE_H client=${SSH_CLIENT%% *}" >> "$LOG_DIR/exports.log"
log "file=$FILE bytes=$BYTES age_h=$AGE_H"
