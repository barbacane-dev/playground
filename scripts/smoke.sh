#!/usr/bin/env bash
# Smoke test for the Barbacane playground. Exercises every demonstrated use case
# against a running stack and exits non-zero if any check fails.
#
# Assumes the stack is already up (docker compose up -d). Waits for the gateway
# to become ready, then runs the checks. Override the endpoints with env vars:
#   BASE_URL   (default http://localhost:8080)  data plane
#   ADMIN_URL  (default http://localhost:8082)  admin API (metrics/health)
#   OAUTH_URL  (default http://localhost:9099)  mock OIDC provider
#   PROM_URL   (default http://localhost:9090)  Prometheus
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
ADMIN_URL="${ADMIN_URL:-http://localhost:8082}"
OAUTH_URL="${OAUTH_URL:-http://localhost:9099}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

pass=0
fail=0

code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

# check "<space-separated acceptable codes>" "<description>" <curl args...>
check() {
  local want="$1"; shift
  local desc="$1"; shift
  local got; got="$(code "$@")"
  if echo " $want " | grep -q " $got "; then
    echo "PASS [$got] $desc"; pass=$((pass + 1))
  else
    echo "FAIL [got $got, want $want] $desc"; fail=$((fail + 1))
  fi
}

echo "== waiting for the gateway =="
i=0
until [ "$(code "$BASE_URL/__barbacane/health")" = "200" ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then echo "gateway did not become ready in time"; exit 1; fi
  sleep 2
done
echo "gateway ready after $((i * 2))s"

# The public CDN asset is seeded by the rustfs-init container after the gateway
# is already serving, so wait for it before the checks race the seeder.
echo "== waiting for the seeded asset =="
i=0
until [ "$(code "$BASE_URL/assets/welcome.txt")" = "200" ]; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then echo "warning: seeded asset not ready after 60s; the CDN check will report it"; break; fi
  sleep 2
done

echo "== core =="
check "200" "GET /stations" "$BASE_URL/stations"
check "400" "GET /stations?country=invalid (schema validation)" "$BASE_URL/stations?country=invalid"
check "401" "GET /bookings without a token" "$BASE_URL/bookings"
check "200" "GET /assets/welcome.txt (public CDN)" "$BASE_URL/assets/welcome.txt"

echo "== OIDC =="
TOKEN="$(curl -s -X POST "$OAUTH_URL/barbacane/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&scope=openid&client_id=playground&client_secret=secret' \
  | python3 -c 'import sys, json; print(json.load(sys.stdin).get("access_token", ""))' 2>/dev/null)"
if [ -n "$TOKEN" ]; then echo "PASS got an access token"; pass=$((pass + 1)); else echo "FAIL no access token"; fail=$((fail + 1)); fi
AUTH="Authorization: Bearer $TOKEN"

echo "== bookings / events / s3 / mcp =="
check "200" "GET /bookings with a token" -H "$AUTH" "$BASE_URL/bookings"
check "202 200" "POST /events/trips/delayed (NATS dispatch)" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"event_type":"trip.delayed","trip_id":"f08d2c3e-8d6f-7f5f-2c1f-4e5f6a7b8c9d","delay_minutes":15,"reason":"weather","timestamp":"2025-03-15T10:30:00Z"}' \
  "$BASE_URL/events/trips/delayed"
check "200 201 204" "PUT /storage/playground/hello.txt" -X PUT -H "$AUTH" -H 'Content-Type: text/plain' -d 'Hello' "$BASE_URL/storage/playground/hello.txt"
check "200" "GET /storage/playground/hello.txt" -H "$AUTH" "$BASE_URL/storage/playground/hello.txt"
check "200 204" "DELETE /storage/playground/hello.txt" -X DELETE -H "$AUTH" "$BASE_URL/storage/playground/hello.txt"
check "200" "POST /__barbacane/mcp initialize" -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"smoke","version":"1"}}}' \
  "$BASE_URL/__barbacane/mcp"

echo "== CORS =="
check "200 204" "OPTIONS /stations (CORS preflight)" \
  -X OPTIONS -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: GET' "$BASE_URL/stations"

echo "== WAF request-phase =="
check "200" "benign query" "$BASE_URL/waf/search?q=paris"
check "403" "SQLi tautology" "$BASE_URL/waf/search?q=1'%20OR%20'1'='1"
check "403" "SQLi union select" "$BASE_URL/waf/search?q=1%20UNION%20SELECT%20x"
check "403" "XSS" "$BASE_URL/waf/search?q=%3Cscript%3Ealert(1)%3C/script%3E"
check "403" "path traversal" "$BASE_URL/waf/search?q=../../etc/passwd"
check "200" "benign JSON body" -X POST -H 'Content-Type: application/json' -d '{"comment":"hi"}' "$BASE_URL/waf/submit"
check "403" "SQLi JSON body" -X POST -H 'Content-Type: application/json' -d '{"comment":"1 UNION SELECT x"}' "$BASE_URL/waf/submit"

echo "== WAF response-phase =="
check "403" "outbound leak /waf/leak (phase 4)" "$BASE_URL/waf/leak"

echo "== admin API =="
check "200" "GET /health" "$ADMIN_URL/health"
check "200" "GET /metrics" "$ADMIN_URL/metrics"

echo "== Prometheus scrape =="
# Give Prometheus a scrape interval to reach the gateway.
target_up=""
for _ in $(seq 1 12); do
  if curl -s "$PROM_URL/api/v1/targets?state=active" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ts = d.get('data', {}).get('activeTargets', [])
sys.exit(0 if any(t['labels'].get('job') == 'barbacane' and t.get('health') == 'up' for t in ts) else 1)
"; then
    target_up=1; break
  fi
  sleep 5
done
if [ -n "$target_up" ]; then echo "PASS Prometheus barbacane target is up"; pass=$((pass + 1)); else echo "FAIL Prometheus barbacane target is not up"; fail=$((fail + 1)); fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
