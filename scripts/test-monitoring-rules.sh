#!/usr/bin/env bash
# monitoring 차트의 알림 룰을 promtool 로 검사한다 — 로컬·CI(.github/workflows/monitoring-rules.yml) 동일.
#   1) helm template 로 렌더 → PrometheusRule 별 rule 파일로 추출
#   2) promtool check rules: 렌더된 전체 룰(차트 기본 포함) 의 YAML·PromQL 문법
#   3) promtool test rules : apps/monitoring/tests/*.yaml 시나리오 (커스텀 룰 동작)
# promtool 은 클러스터와 같은 버전 이미지를 docker 로 돌린다 (설치 불필요, 버전 고정).
#
# 한계: test rules 는 테스트에 적은 시리즈 이름을 믿는다 → 지표 이름 오타로 "절대 안 울리는 룰"
# (2026-11-03 실제 사례) 은 못 잡는다. 그건 실제 Prometheus 대조가 필요.
#
# 사용: ./scripts/test-monitoring-rules.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/apps/monitoring"
TESTS="${TESTS:-$CHART/tests}"
# 클러스터 Prometheus 와 같은 버전 (kubectl get pod -n monitoring prometheus-...-0 -o jsonpath='{..image}')
PROMTOOL_IMAGE="${PROMTOOL_IMAGE:-quay.io/prometheus/prometheus:v3.12.0-distroless}"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# 의존 차트(charts/*.tgz)는 git 에 없다 (ArgoCD 가 직접 받음) → 없을 때만 받는다
if helm dependency list "$CHART" 2>/dev/null | grep -qE 'missing|wrong version'; then
  echo "== helm dependency update"
  helm dependency update "$CHART" >/dev/null
fi

echo "== helm template"
helm template monitoring "$CHART" -n monitoring > "$OUT/rendered.yaml"
# 커스텀 룰 = 이 저장소의 templates/prometheus-rules.yaml 에서 나온 것 (나머지는 차트 기본 룰)
helm template monitoring "$CHART" -n monitoring --show-only templates/prometheus-rules.yaml \
  | awk '/^kind: PrometheusRule/{f=1} f&&/^  name:/{print $2".yaml"; f=0}' > "$OUT/custom.txt"

# PrometheusRule → promtool rule 파일 (metadata.name.yaml, spec 만)
python3 - "$OUT" <<'EOF'
import sys, yaml, pathlib
out = pathlib.Path(sys.argv[1])
n = 0
for d in yaml.safe_load_all((out / "rendered.yaml").read_text()):
    if d and d.get("kind") == "PrometheusRule":
        (out / "rules").mkdir(exist_ok=True)
        (out / "rules" / f'{d["metadata"]["name"]}.yaml').write_text(
            yaml.safe_dump({"groups": d["spec"]["groups"]}, allow_unicode=True, sort_keys=False))
        n += 1
print(f"   PrometheusRule {n}개 추출")
if n == 0:
    sys.exit("PrometheusRule 이 하나도 렌더되지 않음")
EOF

cp "$TESTS"/*.yaml "$OUT/rules/"

promtool() {
  docker run --rm -v "$OUT/rules:/w:ro" -w /w --entrypoint promtool "$PROMTOOL_IMAGE" "$@"
}

cd "$OUT/rules"
CUSTOM=$(cat "$OUT/custom.txt")
DEFAULT=$(ls | grep -v -- '-test\.yaml$' | grep -vxF -f "$OUT/custom.txt")

echo "== promtool check rules — 커스텀 ($(echo $CUSTOM | wc -w)개 파일, lint 경고도 실패 처리)"
# shellcheck disable=SC2086  # 파일 목록을 인자로 펼침
promtool check rules --lint-fatal $CUSTOM

echo "== promtool check rules — 차트 기본 ($(echo $DEFAULT | wc -w)개 파일, 문법 오류만 실패)"
# 차트 기본 룰엔 upstream 중복 recording rule 경고가 있다 (code_verb:apiserver_request_total:increase1h)
# shellcheck disable=SC2086
promtool check rules $DEFAULT > "$OUT/default.log" 2>&1 || { cat "$OUT/default.log"; exit 1; }
grep -c SUCCESS "$OUT/default.log" | xargs -I{} echo "   SUCCESS {}개 파일"
grep -A1 'lint error' "$OUT/default.log" | sed 's/^/   (경고) /' || true

echo "== promtool test rules"
for t in "$TESTS"/*.yaml; do
  echo "-- $(basename "$t")"
  promtool test rules "$(basename "$t")"
done
