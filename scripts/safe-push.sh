#!/usr/bin/env bash
# gitops 저장소는 GitHub Actions가 이미지 태그 bump 커밋을 자주 자동으로
# 올린다 — 사람이 커밋하는 사이에 CI 커밋이 끼어들면 일반 push가
# non-fast-forward 로 거부된다. 매번 수동으로 pull --rebase 하는 대신
# 이 스크립트가 실패 시 자동으로 재시도한다.
#
# 사용: ./scripts/safe-push.sh [git push 인자...]
#   예: ./scripts/safe-push.sh origin main

set -euo pipefail

MAX_RETRIES=5
ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ]; then
  ARGS=(origin main)
fi

for i in $(seq 1 "$MAX_RETRIES"); do
  if git push "${ARGS[@]}"; then
    exit 0
  fi
  echo "push 거부됨 (시도 $i/$MAX_RETRIES) — pull --rebase 후 재시도합니다" >&2
  if ! git pull --rebase "${ARGS[@]}"; then
    echo "pull --rebase 중 충돌 발생 — 자동 처리 불가, rebase 를 되돌립니다" >&2
    git rebase --abort 2>/dev/null || true
    echo "직접 'git pull --rebase' 로 충돌을 해결한 뒤 다시 push 하세요" >&2
    exit 1
  fi
done

echo "push 재시도 ${MAX_RETRIES}회 모두 실패했습니다" >&2
exit 1
