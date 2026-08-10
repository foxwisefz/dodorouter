#!/usr/bin/env bash
#
# Find out, deterministically, which request headers our edge (Caddy) adds
# before a client request reaches Phoenix.
#
# Why a probe rather than reading the Caddyfile: reverse_proxy sets
# X-Forwarded-For / -Proto / -Host with no directive in the config at all, so
# the config is necessary but not sufficient. The wire is the only authority.
#
# Method: send the SAME request twice — once through the edge, once straight at
# the app's own listener on the box — and diff the header names the app
# recorded for each. Every name present only in the edge run is the edge's
# contribution. This is what `@edge_headers` in
# `lib/dodo_router/proxy/adapter.ex` must cover; update that list and the date
# in its comment whenever this prints something new.
#
# Usage (run ON the app server, so DIRECT_URL can bypass Caddy):
#
#   PUBLIC_URL=https://dodorouter.com \
#   DIRECT_URL=http://127.0.0.1:4000 \
#   ROUTER_SLUG=my-router \
#   DODO_API_KEY=dr_... \
#   scripts/edge_header_probe.sh
#
# Optional: DODO_PSQL='docker compose -f ~/lobsterfarm-backend/docker-compose.yml exec -T postgres psql -qtAX -U postgres dodo_router_prod'
# to diff automatically. Without it the script prints the SQL, and the two runs
# are also visible in the UI (log page → "Original Request" → headers).
#
# The probe deliberately asks for one token, and works even if every routing
# step fails: the request log — and its request_headers — is written either way.

set -euo pipefail

: "${PUBLIC_URL:?set PUBLIC_URL, e.g. https://dodorouter.com}"
: "${DIRECT_URL:?set DIRECT_URL, e.g. http://127.0.0.1:4000 (must bypass Caddy)}"
: "${ROUTER_SLUG:?set ROUTER_SLUG}"
: "${DODO_API_KEY:?set DODO_API_KEY (a router API key)}"

MODEL="${MODEL:-probe-model}"
STAMP="$(date +%s)"

probe() {
  local base="$1" tag="$2"
  echo "→ ${tag}: ${base}"
  curl -sS -o /dev/null -w '   HTTP %{http_code}\n' \
    -X POST "${base}/r/${ROUTER_SLUG}/v1/chat/completions" \
    -H "authorization: Bearer ${DODO_API_KEY}" \
    -H "content-type: application/json" \
    -H "x-dodo-edge-probe: ${tag}-${STAMP}" \
    -d "{\"model\":\"${MODEL}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"edge probe\"}]}" \
    || true
}

probe "$PUBLIC_URL" edge
probe "$DIRECT_URL" direct

SQL_EDGE="select request_headers from request_logs where request_headers like '%x-dodo-edge-probe\",\"edge-${STAMP}%' order by inserted_at desc limit 1;"
SQL_DIRECT="select request_headers from request_logs where request_headers like '%x-dodo-edge-probe\",\"direct-${STAMP}%' order by inserted_at desc limit 1;"

if [[ -z "${DODO_PSQL:-}" ]]; then
  cat <<EOF

No DODO_PSQL set — run these two queries and diff the header names yourself,
or open the two newest logs in the UI and compare their "Original Request"
headers:

  ${SQL_EDGE}
  ${SQL_DIRECT}
EOF
  exit 0
fi

names() {
  # request_headers is a JSON array of [name, value] pairs, values redacted.
  printf '%s\n' "$1" | eval "${DODO_PSQL}" | grep '^\[' |
    jq -r '.[][0] | ascii_downcase' | sort -u
}

echo
echo "Headers present only in the run that went through the edge:"
comm -23 <(names "$SQL_EDGE") <(names "$SQL_DIRECT") | sed 's/^/  /'

cat <<'EOF'

Cross-check the rules behind them on the box (defaults will NOT appear here —
only explicit header_up/header_down and trusted_proxies do):

  curl -s localhost:2019/config/ | jq '.. | objects | select(has("headers"))'
EOF
