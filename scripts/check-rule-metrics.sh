#!/usr/bin/env bash
# 커스텀 알림 룰이 참조하는 지표·라벨이 실제 Prometheus 에 있는지 대조한다 (Pi 로컬 전용).
# promtool test rules(CI) 는 테스트에 적은 시리즈 이름을 믿어서 "지표 이름 오타로 절대 안 울리는 룰"을
# 못 잡는다 — 2026-11-03 에 그런 룰 3개(없는 지표명, requests_total 에 없는 status_code 라벨)가 있었다.
# CI 에선 클러스터에 접근할 수 없으니 룰을 고친 뒤 Pi 에서 이걸 함께 돌린다.
#
# 판정 (보존 기간 전체 기준 — 최근 5분에 샘플이 없어도 "없음"으로 오판하지 않게):
#   ERROR  지표 이름이 없음 / 룰에서 쓴 라벨 이름이 그 지표에 없음        → exit 1
#   INFO   이름·라벨은 있는데 셀렉터 값이 안 맞음 (이벤트 때만 생기는 값일 수 있음, 예: reason="OOMKilled")
#   SKIP   EVENT_ONLY: 이벤트가 나야 처음 생기는 지표 (사유와 함께 등록)
# PromQL 은 정규식으로 쪼개지 않고 Prometheus /api/v1/parse_query 의 AST 에서 셀렉터를 뽑는다.
#
# 사용: ./scripts/check-rule-metrics.sh   (PROM_URL 기본 http://localhost:30090)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="${CHART:-$ROOT/apps/monitoring}"
PROM_URL="${PROM_URL:-http://localhost:30090}"

RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
helm template monitoring "$CHART" -n monitoring --show-only templates/prometheus-rules.yaml > "$RENDERED"

PROM_URL="$PROM_URL" python3 - "$RENDERED" <<'EOF'
import json, os, sys, time, urllib.parse, urllib.request, yaml

PROM = os.environ["PROM_URL"]
# 이벤트가 나야 처음 생기는 지표 → 존재 검사 생략 (사유 필수)
EVENT_ONLY = {
    "starlette_exceptions_total": "처리되지 않은 예외가 Pod 기동 후 처음 날 때 시리즈가 생김",
}

def api(path, **params):
    url = f"{PROM}{path}?" + urllib.parse.urlencode(params, doseq=True)
    r = json.load(urllib.request.urlopen(url, timeout=30))
    if r.get("status") != "success":
        sys.exit(f"API 실패 {path}: {r}")
    return r["data"]

# 보존 기간 전체 (values.yaml prometheusSpec.retention: 7d)
start = str(int(time.time() - 7 * 86400))
names = set(api("/api/v1/label/__name__/values", start=start))

def selectors(node):
    """AST 에서 vector/matrix selector 의 (이름, matchers) 를 모은다."""
    if isinstance(node, dict):
        if "matchers" in node and node.get("name"):
            yield node["name"], [m for m in node["matchers"] if m["name"] != "__name__"]
        for v in node.values():
            yield from selectors(v)
    elif isinstance(node, list):
        for v in node:
            yield from selectors(v)

def selector_str(name, ms):
    return name + "{" + ",".join(f"{m['name']}{m['type']}{json.dumps(m['value'])}" for m in ms) + "}"

errors = 0
label_cache = {}
for doc in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not doc or doc.get("kind") != "PrometheusRule":
        continue
    for g in doc["spec"]["groups"]:
        for rule in g["rules"]:
            rname = rule.get("alert") or rule.get("record")
            ast = api("/api/v1/parse_query", query=rule["expr"])
            seen = set()
            for name, ms in selectors(ast):
                sel = selector_str(name, ms)
                if sel in seen:
                    continue
                seen.add(sel)
                if name in EVENT_ONLY:
                    print(f"  SKIP   {rname}: {name} — {EVENT_ONLY[name]}")
                    continue
                if name not in names:
                    print(f"  ERROR  {rname}: 지표 없음 — {name}")
                    errors += 1
                    continue
                if name not in label_cache:
                    label_cache[name] = set(api("/api/v1/labels", **{"match[]": name, "start": start}))
                missing = [m["name"] for m in ms if m["name"] not in label_cache[name]]
                if missing:
                    print(f"  ERROR  {rname}: {name} 에 없는 라벨 {missing} (있는 라벨: {sorted(label_cache[name] - {'__name__'})})")
                    errors += 1
                    continue
                n = len(api("/api/v1/series", **{"match[]": sel, "start": start}))
                if n == 0:
                    print(f"  INFO   {rname}: 이름·라벨은 있으나 값 매칭 0 — {sel}")
                else:
                    print(f"  OK     {rname}: {sel} ({n} series)")

print(f"\n결과: ERROR {errors}개")
sys.exit(1 if errors else 0)
EOF
