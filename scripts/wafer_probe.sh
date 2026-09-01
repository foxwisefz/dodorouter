#!/usr/bin/env bash
#
# Characterize the Wafer (pass.wafer.ai) provider surface for the two adapter
# contracts that can only be satisfied by observation (dodo_router-uzo):
#
#   1. Context Limit Handling — what an oversized request actually returns
#      (status code, error envelope, code/message), so the observed pattern can
#      be documented in CLAUDE.md's Known Provider Patterns and checked against
#      `Adapter.context_overflow?/2`.
#   2. Usage & Cache Token Normalization — where cached tokens appear in the
#      usage object on a cache hit. If it is not OpenAI's
#      `prompt_tokens_details.cached_tokens`, the adapter needs a
#      `convert_usage/1` rename plus a seam test through
#      `Adapter.extract_usage/1`.
#
# Why a probe rather than reading the docs: Wafer's docs (2026-09) document
# neither the cache fields in the usage object nor the overflow error body.
# models.dev lists cache_read pricing for every Wafer model, so *some* field
# must exist. The wire is the only authority.
#
# Usage:
#
#   WAFER_API_KEY=wfr_... scripts/wafer_probe.sh
#
# Without WAFER_API_KEY it still runs the unauthenticated probes (model
# catalog, auth error envelope) and skips the two that need credentials.
# Keys are minted at https://app.wafer.ai.
#
# Optional: MODEL (default Kimi-K2.6 — the smallest context window in the
# catalog at 262,144 tokens, so the overflow probe stays cheap to build),
# OUT_DIR (default: a fresh mktemp dir; raw response bodies land there).

set -euo pipefail

BASE_URL="${BASE_URL:-https://pass.wafer.ai/v1}"
MODEL="${MODEL:-Kimi-K2.6}"
OUT_DIR="${OUT_DIR:-$(mktemp -d /tmp/wafer_probe.XXXXXX)}"

say() { printf '\n== %s\n' "$*"; }

post_chat() { # name, body-file
  local name="$1" body="$2" auth=()
  [ -n "${WAFER_API_KEY:-}" ] && auth=(-H "Authorization: Bearer $WAFER_API_KEY")
  curl -sS -m 300 -o "$OUT_DIR/$name.json" -w '%{http_code}' \
    -X POST "$BASE_URL/chat/completions" \
    -H "Content-Type: application/json" "${auth[@]}" \
    --data-binary "@$body"
}

say "1. Model catalog (unauthenticated): context, reasoning efforts, cache pricing"
curl -sS -m 30 "$BASE_URL/models" >"$OUT_DIR/models.json"
python3 - "$OUT_DIR/models.json" <<'PY'
import json, sys
for m in json.load(open(sys.argv[1]))["data"]:
    w = m.get("wafer", {})
    eff = w.get("capabilities", {}).get("reasoning_effort", {})
    price = w.get("pricing", {})
    print(f'{m["id"]}: ctx={w.get("context_length")} '
          f'efforts={eff.get("efforts")} (default={eff.get("default")}) '
          f'cache_read={price.get("cache_read_cents_per_million")}c/M')
PY

say "2. Auth error envelope (no key, then bogus key)"
printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' "$MODEL" >"$OUT_DIR/tiny.json"
status=$(WAFER_API_KEY="" post_chat no_key "$OUT_DIR/tiny.json"); echo "no key    -> HTTP $status: $(cat "$OUT_DIR/no_key.json")"
status=$(WAFER_API_KEY="wfr_bogus" post_chat bad_key "$OUT_DIR/tiny.json"); echo "bogus key -> HTTP $status: $(cat "$OUT_DIR/bad_key.json")"

if [ -z "${WAFER_API_KEY:-}" ]; then
  say "WAFER_API_KEY not set — skipping the overflow and cache probes (the two this script exists for). Raw output in $OUT_DIR"
  exit 0
fi

say "3. Context overflow: oversized prompt against $MODEL"
# ~400k whitespace-separated numbers tokenize to well past 262,144 tokens.
python3 - "$MODEL" >"$OUT_DIR/overflow_req.json" <<'PY'
import json, sys
filler = " ".join(str(n) for n in range(400_000))
print(json.dumps({"model": sys.argv[1], "max_tokens": 1,
                  "messages": [{"role": "user", "content": filler}]}))
PY
status=$(post_chat overflow "$OUT_DIR/overflow_req.json")
echo "overflow -> HTTP $status"
head -c 2000 "$OUT_DIR/overflow.json"; echo

say "4. Cache fields: identical large prefix sent twice"
# ~8k tokens of stable prefix — comfortably past any minimum cacheable length.
python3 - "$MODEL" >"$OUT_DIR/cache_req.json" <<'PY'
import json, sys
filler = " ".join(str(n) for n in range(8_000))
print(json.dumps({"model": sys.argv[1], "max_tokens": 5,
                  "messages": [{"role": "user", "content": filler + "\nSay OK."}]}))
PY
for run in cache_1 cache_2; do
  status=$(post_chat "$run" "$OUT_DIR/cache_req.json")
  echo "$run -> HTTP $status usage: $(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("usage")))' "$OUT_DIR/$run.json" 2>/dev/null || echo '<no usage — see raw body>')"
  sleep 3
done

say "Raw bodies in $OUT_DIR. Next: document both observed patterns in CLAUDE.md's Known Provider Patterns; if cached tokens are not under prompt_tokens_details.cached_tokens, add a convert_usage/1 rename to Adapters.Wafer with a seam test. Then close dodo_router-uzo."
