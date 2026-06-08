# 🗄️ PostgreSQL for Clog (Custom Chart)

> PostgreSQL 16 alpine, 직접 작성한 Helm chart.
> Bitnami chart 의 ARM64 호환성 문제로 공식 이미지 + 커스텀 chart 로 전환.

## 왜 커스텀 chart?

| 시도 | 결과 |
|---|---|
| Bitnami PostgreSQL chart | `:16` 등 안정 태그 제거됨, `latest` 만 ARM64 지원 |
| 공식 `postgres:16-alpine` + 직접 작성 ⭐ | multi-arch 확실, 제어권 100% |

## 구성

- **이미지**: `postgres:16-alpine` (multi-arch, ~80MB)
- **Architecture**: Standalone (단일 인스턴스)
- **Storage**: 4Gi PVC (local-path)
- **Auth**: K8s Secret 분리 (`postgres-credentials`)
- **DB**: `clog_dev` (clog 사용자 소유, 초기화 스크립트가 생성)
- **Tuning**: `postgresql.conf` 가 ConfigMap 으로 mount

## 사전 준비

이 chart 를 배포하기 전에 **Secret 을 먼저 생성**해야 합니다.
[../../SECRET_SETUP.md](../../SECRET_SETUP.md) 참조.

## 디렉토리 구조

```
apps/postgres/
├── Chart.yaml              # 의존성 없음
├── values.yaml             # 설정값
├── README.md
└── templates/
    ├── _helpers.tpl        # 헬퍼 함수
    ├── configmap.yaml      # postgresql.conf + init SQL
    ├── service.yaml        # regular + headless
    └── statefulset.yaml    # ⭐ 핵심
```

## 접속

### 클러스터 내부 (앱 → DB)

```
Host: postgres.dev.svc.cluster.local
Port: 5432
Database: clog_dev
User: clog (앱용) 또는 postgres (관리용)
```

### 외부에서 (port-forward, 디버깅용)

```bash
kubectl port-forward -n dev svc/postgres 5432:5432

# 다른 터미널 — clog 사용자로
PGPASSWORD=$(kubectl get secret postgres-credentials -n dev \
  -o jsonpath='{.data.clog-password}' | base64 -d) \
  psql -h localhost -U clog -d clog_dev

# 또는 postgres 관리자로
PGPASSWORD=$(kubectl get secret postgres-credentials -n dev \
  -o jsonpath='{.data.postgres-password}' | base64 -d) \
  psql -h localhost -U postgres -d postgres
```

## 검증 명령

```bash
# Pod 상태
kubectl get statefulset postgres -n dev
kubectl get pod postgres-0 -n dev

# PVC 확인
kubectl get pvc -n dev | grep postgres

# 로그
kubectl logs -n dev postgres-0

# DB 안에서
\l              # 데이터베이스 목록
\du             # 사용자 목록
\c clog_dev     # DB 전환
\dt             # 테이블 목록 (지금은 비어있음)
\dx             # extension 목록 (pgcrypto 있어야 함)
```

## 환경별 분리 (추후)

```
[현재]
- dev: postgres-dev (apps/postgres + values.yaml)

[추후 prod 추가 시]
- values-prod.yaml 추가
- argocd/applications/postgres-prod.yaml 추가
- prod 네임스페이스에 별도 Secret 생성
```

## 백업 전략 (추후)

지금은 미설정. 검토 옵션:
1. **CronJob + pg_dump** ⭐ 단순, 권장
2. **Velero**: K8s 전체 백업 (PVC 포함)
3. **CloudNativePG로 전환**: built-in PITR

## ADR 참조

- ADR-XXX: PostgreSQL 초기 구성 — 커스텀 chart 채택
- ADR-XXX: Bitnami → 공식 이미지 전환 (ARM64 호환성)
