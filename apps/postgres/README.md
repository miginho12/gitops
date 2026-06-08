# 🗄️ PostgreSQL for Clog

> Bitnami PostgreSQL 16 wrapper chart for Clog dev environment.

## 구성

- **Chart**: Bitnami PostgreSQL 15.5.38 (PostgreSQL 16.4)
- **Architecture**: Standalone (단일 인스턴스, 단일 노드 환경 고려)
- **Storage**: 4Gi PVC (local-path)
- **Auth**: K8s Secret 분리 (`postgres-credentials`)
- **DB**: `clog_dev` (clog 사용자 소유)

## 사전 준비

이 chart 를 배포하기 전에 **Secret 을 먼저 생성**해야 합니다.
[SECRET_SETUP.md](../SECRET_SETUP.md) 참조.

## 배포

ArgoCD 가 `argocd/applications/postgres-dev.yaml` 을 자동 적용.

수동 배포 (디버깅용):

```bash
helm dependency build apps/postgres
helm install postgres apps/postgres -n dev -f apps/postgres/values.yaml
```

## 접속

### 클러스터 내부에서

```
Host: postgres.dev.svc.cluster.local
Port: 5432
Database: clog_dev
User: clog (앱용) 또는 postgres (관리용)
```

### 외부에서 (port-forward)

```bash
kubectl port-forward -n dev svc/postgres 5432:5432

# 다른 터미널
PGPASSWORD=$(kubectl get secret postgres-credentials -n dev \
  -o jsonpath='{.data.clog-password}' | base64 -d) \
  psql -h localhost -U clog -d clog_dev
```

## 환경별 분리 (추후)

```
[현재]
- dev: postgres-dev (apps/postgres + values-dev.yaml)

[추후 prod 추가 시]
- values-prod.yaml 추가
- argocd/applications/postgres-prod.yaml 추가
- prod 네임스페이스에 별도 Secret 생성
```

## 백업 전략 (운영 시)

현재는 미설정. 다음 옵션 검토 예정:

1. **CronJob + pg_dump**: 가장 단순
2. **Velero**: K8s 전체 백업 (PVC 포함)
3. **CloudNativePG로 전환**: built-in 백업/PITR

## ADR 참조

- `ADR-XXX: PostgreSQL 초기 구성 — Bitnami 단일 인스턴스` (다음에 작성)
