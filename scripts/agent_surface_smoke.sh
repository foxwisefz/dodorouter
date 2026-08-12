#!/usr/bin/env bash
# Walks the agent surface end to end against a running server.
#
# This exists because the interesting parts of that surface are things a unit
# test asserts but a person has to see: that an unauthenticated call is
# refused, that a token without logs:read_bodies gets a visible marker rather
# than a missing key, and that every one of these attempts turns up in the
# audit trail at /agent-tokens.
#
#   scripts/agent_surface_smoke.sh <token> [router-slug] [base-url]
#
# The slug is optional — the script discovers one from GET /agent, which is
# the same thing an agent holding only a token has to do.
#
# Mint the token at <base-url>/agent-tokens first. To exercise the withholding
# path, mint a second one WITHOUT "Read prompts and responses" and run again.

set -uo pipefail

TOKEN="${1:-}"
SLUG="${2:-}"
BASE="${3:-http://localhost:4000}"

if [ -z "$TOKEN" ]; then
  echo "usage: $0 <token> [router-slug] [base-url]" >&2
  echo "mint one at $BASE/agent-tokens" >&2
  exit 64
fi

command -v jq >/dev/null || { echo "needs jq" >&2; exit 69; }

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
note() { printf '       %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILED=0
BODY=""
STATUS=""
AUTH=(-H "Authorization: Bearer $TOKEN")

# Sets $STATUS and $BODY. Deliberately NOT called as `status=$(call ...)`:
# command substitution runs in a subshell, so every assignment made in here
# would be thrown away and $BODY would read as unset under `set -u`.
call() {
  local out
  out=$(curl -sS -w '\n%{http_code}' "$@" 2>/dev/null) || { BODY=''; STATUS=000; return; }
  BODY=$(printf '%s' "$out" | sed '$d')
  STATUS=$(printf '%s' "$out" | tail -n1)
}

section "Reachability"
call "$BASE/health"
[ "$STATUS" = "200" ] && pass "server is up at $BASE" || {
  fail "no server at $BASE (status $STATUS) — start it with: mix phx.server"
  exit 1
}

section "The credential is required"
call "$BASE/r/${SLUG:-any}/logs"
if [ "$STATUS" = "401" ]; then
  pass "no token is refused (401)"
  challenge=$(curl -sSI "$BASE/r/${SLUG:-any}/logs" 2>/dev/null | grep -i '^www-authenticate' || true)
  [ -n "$challenge" ] && note "challenge: ${challenge%$'\r'}"
else
  fail "expected 401 without a token, got $STATUS"
fi

section "Self-onboarding — GET /agent"
call "${AUTH[@]}" "$BASE/agent"
if [ "$STATUS" = "200" ]; then
  pass "token is \"$(printf '%s' "$BODY" | jq -r '.token.name')\" holding: $(printf '%s' "$BODY" | jq -r '.token.scopes | join(", ")')"
  printf '%s' "$BODY" | jq -r '.routers[] | "       \(.slug)  (\(.name))"'
  # The point of this endpoint: a caller holding only a base URL and a token
  # can get here without being told a slug out of band.
  [ -z "$SLUG" ] && SLUG=$(printf '%s' "$BODY" | jq -r '.routers[0].slug // empty')
  if [ -z "$SLUG" ]; then
    fail "$(printf '%s' "$BODY" | jq -r '.next')"
    exit 1
  fi
  note "using router: $SLUG"
else
  fail "unexpected status $STATUS from the entry point"
  exit 1
fi

section "Discovery — GET /r/$SLUG/agent"
call "${AUTH[@]}" "$BASE/r/$SLUG/agent"
if [ "$STATUS" = "200" ]; then
  pass "guide returned"
  note "$(printf '%s' "$BODY" | jq -r '.endpoints | length') endpoints described"
  printf '%s' "$BODY" | jq -e '.guide | contains("{{BASE}}") | not' >/dev/null \
    && pass "guide is addressed to this router, not a placeholder" \
    || fail "guide still contains unsubstituted placeholders"
elif [ "$STATUS" = "404" ]; then
  fail "router '$SLUG' is not reachable by this token (404) — check its reach at $BASE/agent-tokens"
  exit 1
else
  fail "unexpected status $STATUS"
fi

section "Logs — GET /r/$SLUG/logs"
call "${AUTH[@]}" "$BASE/r/$SLUG/logs?limit=5"
if [ "$STATUS" = "200" ]; then
  total=$(printf '%s' "$BODY" | jq -r '.returned')
  pass "$total log(s) returned"
  printf '%s' "$BODY" | jq -r '.data[] | "       \(.model // "?")  \(.total_tokens // 0) tok  evaluable=\(.evaluable)\(if .not_evaluable_because then " (\(.not_evaluable_because))" else "" end)"'
  LOG_ID=$(printf '%s' "$BODY" | jq -r 'first(.data[] | select(.evaluable) | .id) // empty')
elif [ "$STATUS" = "403" ]; then
  note "this token lacks logs:read — skipping"
  LOG_ID=""
else
  fail "unexpected status $STATUS"; LOG_ID=""
fi

if [ -n "${LOG_ID:-}" ]; then
  section "Bodies — GET /r/$SLUG/logs/$LOG_ID"
  call "${AUTH[@]}" "$BASE/r/$SLUG/logs/$LOG_ID"
  if [ "$STATUS" = "200" ]; then
    withheld=$(printf '%s' "$BODY" | jq -r '.request_body.withheld // empty')
    if [ -n "$withheld" ]; then
      pass "bodies withheld, and the response says so"
      note "\"$withheld\""
      note "this call is recorded with returned_bodies=false"
    else
      pass "bodies returned (this token holds logs:read_bodies)"
      note "this call is recorded with returned_bodies=true — check $BASE/agent-tokens"
    fi
  else
    fail "unexpected status $STATUS"
  fi
fi

section "Targets — GET /r/$SLUG/evals/targets"
call "${AUTH[@]}" "$BASE/r/$SLUG/evals/targets"
case "$STATUS" in
  200)
    pass "$(printf '%s' "$BODY" | jq -r '.data | length') provider key(s) offered"
    # Label, not just provider name: three keys for the same provider render
    # identically without it, and picking a candidate means picking a key.
    printf '%s' "$BODY" | jq -r '.data[] | "       \(.provider_name) · \(.label // "unlabelled"): \(.models | length) models"'
    ;;
  403) note "this token lacks evals:read — skipping" ;;
  *)   fail "unexpected status $STATUS" ;;
esac

section "Result"
if [ "$FAILED" = "0" ]; then
  printf '  every check passed\n'
else
  printf '  \033[31msomething above failed\033[0m\n'
fi
printf '  Every call just made — including the refused ones — is at %s/agent-tokens\n\n' "$BASE"
exit "$FAILED"
