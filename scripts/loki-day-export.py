# Loki 에서 UTC 하루치 로그를 NDJSON 으로 내보낸다 (2026-11-10, 감사 M5 — 로그 외부 백업).
# backup-export.sh 의 `logs <YYYY-MM-DD>` 가 호출한다: stdout → gzip → age → 노트북.
#
# 사용: python3 -I loki-day-export.py <loki_base_url> <YYYY-MM-DD> <LogQL selector>
# stdout: 한 줄에 {"ts": "<ns>", "labels": {...}, "line": "..."} — 시간순
# stderr: "lines=<n> raw=<bytes>"
# 실패(exit≠0): Loki 오류, 또는 내보낸 줄 수 ≠ Loki 의 count_over_time (완결성 검증)
#
# 왜 시간 창 분할인가: query_range 는 요청당 최대 5000줄. "마지막 ts 부터 다음 페이지" 방식은
# 여러 스트림이 섞이면 경계에서 줄이 빠졌다(11-10 실측 8908/8924). 겹치지 않는 [start, end) 창으로
# 나누고, 창이 5000줄로 꽉 차면 반으로 쪼개 다시 받는다 → 실측 8924/8924.
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

LIMIT = 5000
HOUR_NS = 3600 * 10**9
MIN_WINDOW_NS = 10**6  # 1ms 창에 5000줄 넘으면 포기 (비현실적 — 무한 분할 방지)


def get(base: str, path: str, **params):
    url = f"{base}{path}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=120) as r:
        body = json.load(r)
    if body.get("status") != "success":
        sys.exit(f"loki 오류: {str(body)[:200]}")
    return body["data"]["result"]


def fetch(base: str, selector: str, start: int, end: int) -> list[tuple[int, dict, str]]:
    res = get(base, "/loki/api/v1/query_range", query=selector, start=start, end=end,
              limit=LIMIT, direction="forward")
    entries = [(int(ts), s["stream"], line) for s in res for ts, line in s["values"]]
    if len(entries) >= LIMIT:
        if end - start <= MIN_WINDOW_NS:
            sys.exit(f"창 {start}~{end} 에 {LIMIT}줄 이상 — 분할 불가")
        mid = (start + end) // 2
        return fetch(base, selector, start, mid) + fetch(base, selector, mid, end)
    # end 포함 여부가 버전마다 달라도 겹치지 않게 [start, end) 로 자른다
    return [e for e in entries if start <= e[0] < end]


def main() -> None:
    base, day, selector = sys.argv[1], sys.argv[2], sys.argv[3]
    d0 = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start = int(d0.timestamp()) * 10**9
    end = int((d0 + timedelta(days=1)).timestamp()) * 10**9

    n = raw = 0
    for h in range(24):
        part = fetch(base, selector, start + h * HOUR_NS, start + (h + 1) * HOUR_NS)
        part.sort(key=lambda e: e[0])
        for ts, labels, line in part:
            rec = json.dumps({"ts": str(ts), "labels": labels, "line": line}, ensure_ascii=False) + "\n"
            sys.stdout.write(rec)
            n += 1
            raw += len(rec.encode())
    sys.stdout.flush()

    # 완결성: count_over_time 범위 (t-1d, t] → t = end-1 이면 [start, end) 와 같다
    exp = get(base, "/loki/api/v1/query", query=f"sum(count_over_time({selector}[1d]))", time=end - 1)
    expected = int(float(exp[0]["value"][1])) if exp else 0
    print(f"lines={n} raw={raw}", file=sys.stderr)
    if n != expected:
        sys.exit(f"줄 수 불일치: 내보냄 {n} / Loki {expected}")


if __name__ == "__main__":
    main()
