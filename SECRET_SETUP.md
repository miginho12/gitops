# PostgreSQL Secret 수동 생성 가이드

> ⚠️ 이 파일은 **참고용**입니다. 절대 git에 실제 비밀번호를 커밋하지 마세요.
> Secret 은 진호님이 라즈베리파이에서 직접 `kubectl create secret` 으로 생성합니다.

## 변경 사항 (Bitnami → 커스텀 chart)

- **이전**: `postgres-password`, `clog-password`, `replication-password` (3개)
- **현재**: `postgres-password`, `clog-password` (2개) — replication 불필요

이전에 Secret 만들었으면 삭제 후 재생성:
```bash
kubectl delete secret postgres-credentials -n dev --ignore-not-found
```

---

## 1. 강력한 비밀번호 생성

```bash
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)
CLOG_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)

# 확인 (백업 필수!)
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo "CLOG_PASSWORD=$CLOG_PASSWORD"
```

> ⚠️ **백업**: 위 두 비밀번호를 1Password, Bitwarden, KeePassXC 등 비밀번호 관리자에 안전하게 저장.
> 특히 `CLOG_PASSWORD` 는 다음 세션에 clog-backend 의 DATABASE_URL 에 사용됨.

## 2. dev 네임스페이스 + Secret 생성

```bash
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-credentials -n dev \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=clog-password="$CLOG_PASSWORD"
```

## 3. 확인

```bash
kubectl get secret postgres-credentials -n dev
kubectl describe secret postgres-credentials -n dev
```

`Data` 섹션에 보여야 함:
- `postgres-password` (XX bytes)
- `clog-password` (XX bytes)

## 4. 비밀번호 확인 (필요시)

```bash
# clog 사용자 비밀번호 보기 (다음 세션에 사용)
kubectl get secret postgres-credentials -n dev \
  -o jsonpath='{.data.clog-password}' | base64 -d
echo ""
```

## 5. 다음 사용 (참고)

진호님 `clog-backend` 의 환경변수에 다음 형식으로 사용 예정:

```
DATABASE_URL=postgresql+asyncpg://clog:<CLOG_PASSWORD>@postgres.dev.svc.cluster.local:5432/clog_dev
```

이건 다음 세션 (clog-backend DB 연동)에서 작업.
