# 🔑 sealed-secrets 마스터 키 백업·복구 Runbook

Git 의 SealedSecret 은 이 클러스터의 컨트롤러 키로만 풀린다. **노드(디스크)를 잃으면 DB 덤프가
있어도 비밀값(JWT 키·DB·Redis·MinIO·카카오·SMTP·cloudflared 토큰)을 하나도 못 푼다** → 키를 Pi 밖에 둔다.
(2026-11-09 감사 H4 에서 추가. 그 전까지 키는 Pi 디스크에만 있었다.)

## 사양

| 항목 | 내용 |
| --- | --- |
| 대상 | `sealed-secrets` 네임스페이스, 라벨 `sealedsecrets.bitnami.com/sealed-secrets-key` 인 Secret **전부** |
| 왜 전부 | 컨트롤러가 30일마다 새 키를 만들고 옛 키도 계속 쓴다. 11-09 실측: SealedSecret 18개가 모두 첫 키(07-16)로 봉인 — **최신 키만 있으면 0/18 복구** |
| 형식 | `kind: List` JSON (uid·resourceVersion 등 클러스터 고유값 제거, `kubectl apply` 로 바로 복구) |
| 암호화 | age (노트북 공개키 `~/.config/clog-backup/recipient`). 평문은 Pi 디스크에 쓰지 않음(파이프만) |
| 전달 | 노트북 → Pi pull (DB 외부 복제와 같은 forced-command SSH 키). `scripts/backup-export.sh keys` |
| 보관 | 노트북 `%USERPROFILE%\clog-backup\sealed-keys\sealed-keys-<개수>-<최신키 UTC>.json.age` (전부 보관) |
| 감시 | 노트북 검증 후 `ack-keys` → textfile 지표 → `ClogSealedKeysBackupStale`(새 키 72h 미백업), `ClogSealedKeysBackupMetricMissing`(지표 1h 없음) |

⚠️ 노트북 `keys\age.key` 는 이 번들을 여는 유일한 키다. **age.key + 공개 Git 저장소 = 모든 비밀값**이므로
age.key 사본은 노트북 밖 안전한 곳(비밀번호 관리자 등)에 보관하고, 절대 Git·클라우드 드라이브에 두지 않는다.

## 흐름

```txt
노트북 pull-backup.ps1 (매일 09:00·로그온)
  ssh keys      → Pi: 키 전부 → List JSON → age 암호화 → stdout   (stderr: keys=<n> bundle=<id>)
  검증           → 복호화 → kind=List → 개수 일치 → 키마다 tls.key·tls.crt 존재
  저장           → 암호문만 sealed-keys\<id>.json.age (같은 번들이 이미 있으면 SKIP)
  ssh ack-keys  → Pi: /var/lib/node_exporter/textfile_collector/clog_sealed_keys_backup.prom 갱신
```

## 복구 A — 새 클러스터에 키 되살리기 (정상 경로)

```bash
# 1) sealed-secrets 차트 설치(ArgoCD 앱 sync) — 컨트롤러가 새 키를 하나 만들어도 상관없다
# 2) 노트북 번들을 클러스터에 넣는다 (가장 최근 번들 하나면 그 시점의 키 전부가 들어 있다)
age -d -i keys/age.key sealed-keys-<n>-<ts>.json.age | kubectl apply -f -
# 3) 컨트롤러 재시작 → 라벨 붙은 키를 전부 다시 읽는다
kubectl -n sealed-secrets rollout restart deploy/sealed-secrets-controller
# 4) 확인: SealedSecret 이 Secret 으로 풀렸는지
kubectl get sealedsecrets -A   # STATUS 가 비어 있거나 Synced
```

## 복구 B — 클러스터 없이 비밀값 꺼내기 (비상)

```bash
# 키 PEM 을 RAM(tmpfs)에만 풀고 끝나면 지운다
K=$(mktemp -d /dev/shm/sk.XXXX); trap 'rm -rf "$K"' EXIT
age -d -i keys/age.key sealed-keys-<n>-<ts>.json.age | python3 -c '
import json,sys,base64,os
for s in json.load(sys.stdin)["items"]:
    open(os.path.join(sys.argv[1], s["metadata"]["name"]+".pem"),"wb").write(base64.b64decode(s["data"]["tls.key"]))' "$K"
grep -v '{{' apps/clog/templates/sealed-secret-clog-jwt-keys-prod.yaml \
  | kubeseal --recovery-unseal --recovery-private-key "$(ls $K/*.pem | paste -sd,)" -o yaml
```

## 리허설 기록

| 날짜 | 내용 | 결과 |
| --- | --- | --- |
| 2026-11-09 | Pi 에서 키 4개로 Git 의 SealedSecret 전부 오프라인 복구(B 방식, 값은 출력 안 함·키 이름만) | **18/18 OK** |
| 2026-11-09 | 키 하나씩만으로 복구 시도 | 07-16 키 18/18, 08-15·09-14·10-14 키 각 0/18 → "전부" 백업 근거 |
| — | 복구 A (새 클러스터) | 미리허설 — IaC 단계에서 새 클러스터로 진행 예정 |
