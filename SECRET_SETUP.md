# PostgreSQL Secret 수동 생성 가이드

> Secret 은 라즈베리파이에서 직접 `kubectl create secret` 으로 생성

## 1. 강력한 비밀번호 생성

```bash
# 3개 다 다른 비밀번호로
openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
# 위 명령 3번 실행해서 각각 다른 비번 만들기

# 또는 한 번에:
echo "POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
echo "CLOG_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
echo "REPLICATION_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
```

3개를 메모장에 임시 저장 (나중에 .env 저장).

## 2. dev 네임스페이스에 Secret 생성

```bash
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-credentials -n dev \
  --from-literal=postgres-password="<위에서 생성한 POSTGRES_PASSWORD>" \
  --from-literal=clog-password="<위에서 생성한 CLOG_PASSWORD>" \
  --from-literal=replication-password="<위에서 생성한 REPLICATION_PASSWORD>"
```

## 3. 확인

```bash
kubectl get secret postgres-credentials -n dev
kubectl describe secret postgres-credentials -n dev
```

키 이름 보여야 함:
- postgres-password
- clog-password
- replication-password

## 4. 비밀번호 확인 (필요시)

```bash
# 특정 키의 비밀번호 보기 (base64 디코딩)
kubectl get secret postgres-credentials -n dev \
  -o jsonpath='{.data.clog-password}' | base64 -d
echo ""
```

## 5. 백업 — 비밀번호를 잃지 않게

- 1Password, Bitwarden 같은 비밀번호 관리자
- 또는 암호화된 노트 (KeePassXC 등)
- 또는 진호님 노션의 비공개 페이지 (HTTPS + 본인만 접근)

## 6. 다음 사용

`clog-backend` 의 `.env` 또는 ConfigMap 에 다음 형식:

```
DATABASE_URL=postgresql+asyncpg://clog:<CLOG_PASSWORD>@postgres:5432/clog_dev
```
