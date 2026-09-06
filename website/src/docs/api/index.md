---
title: API Reference
navTitle: Overview & Auth
description: Base URL, authentication, the full endpoint list, why the model field is ignored, and the error format.
order: 5
---

# API reference

## Base URL & authentication

All proxy endpoints are scoped per router: `{base_url}/r/{router_slug}/v1/…`. In every example in this reference, `{base_url}` is `https://api.dodorouter.com` for the hosted service (or your own domain if self-hosted), and `{router}` is your router's slug — swap both in before running any command.

Authenticate with your router's API key, either as a Bearer token or, if your client library doesn't support custom bearer tokens, as `x-api-key`:

```http
Authorization: Bearer sk-dodo-YOUR_KEY
# or:
x-api-key: sk-dodo-YOUR_KEY
```

A missing or invalid key returns `401` with `{"error":{"message":"Invalid API key",…}}` (verified). On the hosted service, a router whose owner has no active subscription returns `402` instead — not applicable to self-hosted instances unless you've enabled billing yourself.

## Endpoints

| Method & path | Purpose |
|---|---|
| `POST /r/{slug}/v1/chat/completions` | [OpenAI Chat Completions](/docs/api/chat-completions/) format, sync or streaming |
| `POST /r/{slug}/v1/messages` | [Anthropic Messages](/docs/api/messages/) format, sync or streaming |
| `POST /r/{slug}/v1/responses` | [OpenAI Responses API](/docs/api/responses/) format, sync or streaming |
| `GET /r/{slug}/v1/models` | Returns a single synthetic model entry named after the router slug (for clients that require a models list before use) |
| `POST /r/{slug}/recordings/start` | Start a recording, optional `{"name":"…"}` body |
| `GET /r/{slug}/recordings/active` | Currently active recording, or 404 |
| `POST /r/{slug}/recordings/active/stop` | Stop the active recording |
| `POST /v1/chat/completions` | Legacy endpoint, identical behavior to the router-scoped chat/completions route above, kept for backwards compatibility |
| `GET /health` | No auth. `{"status":"ok"}`, 503 if DB is unreachable or the instance is draining for a hot upgrade |
| `GET /api/version` | No auth. Running app version |

Every proxy response also carries `x-request-id`, `x-timing-total-ms`, and `x-timing-provider-ms` response headers.

## Cache diagnostics

Cache diagnostics group requests using your router's existing session header (default `x-session-id`). No additional client headers are needed. DodoRouter does not infer a client's internal branch or turn identifiers.

Diagnostics use router-scoped HMAC-SHA256 derived from the deployment's `secret_key_base`. Rotating that secret makes comparisons across the rotation unavailable. Signatures and diagnosis metadata live and expire with the request log; body removal alone does not remove them. Component byte sizes and bounded item signatures are retained, not exact token counts or token offsets. Requests over 4,096 combined message/tool/system items have no fingerprint. Provider cache-read/write token totals remain the provider's reported usage.

For diagnosis, DodoRouter records the final outbound `prompt_cache_key` as a keyed hash when present, explicit `prompt_cache_retention`/`prompt_cache_options` settings, and cache breakpoints at native request/tool/message/content-block positions. It does not add caching parameters or assume that a client-supplied field survived format conversion. Routing identity and attempt timing are exposed in [MCP cache evidence](/docs/agent-access/#cache-evidence-without-prompt-access); prompt text and raw component hashes remain private.

## Idempotency

All three proxy endpoints accept an `Idempotency-Key` request header ([Stripe semantics](https://stripe.com/docs/idempotency), the [IETF `Idempotency-Key` draft](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/)). Send a unique key per logical request — a row ID, a question ID — and a retry with the same key returns the stored response **without calling the provider or billing you again**. Built for batch work: an interrupted 8,000-row backfill resumes at zero cost, and "the provider answered but my own DB write failed" stops meaning paying twice for the same answer.

```bash
curl https://api.dodorouter.com/r/{slug}/v1/chat/completions \
  -H "Authorization: Bearer $DODO_KEY" \
  -H "Idempotency-Key: backfill-row-3821" \
  -d '{"model":"default","messages":[{"role":"user","content":"…"}]}'
```

The exact contract:

- **Keys are scoped per router** and expire after **24 hours**; after that the same key executes fresh.
- Replayed responses carry an **`Idempotent-Replayed: true`** header, so you can tell a re-served answer from a fresh one.
- Reusing a key with a **different request body is a `409`** (`idempotency_key_reused`) — never served-anyway, because a silently wrong answer is worse than a loud error.
- A retry that arrives **while the original is still executing** gets a `409` (`idempotency_in_progress`); retry after it completes.
- Only **successful** responses are stored: an error outcome releases the key so the retry executes fresh, and a response too large to store in full is also re-executed rather than replayed truncated.
- **Streaming requests are refused** (`400`) when they carry the header — stored responses replay as JSON, and silently dropping the guarantee would be worse than saying no. Retries of a stored answer work in either non-streaming format: the response is stored provider-agnostically and re-rendered in whichever endpoint's format you retry against.
- Replays appear in your logs as **zero-cost, zero-token rows** linked to the original, so spend analytics count each answer exactly once. The header itself is consumed by DodoRouter and never forwarded upstream (recorded in the request's fidelity trace).

## The `model` field is ignored

This trips people up, so it's worth stating plainly: whatever `model` you put in the request body is discarded. DodoRouter always substitutes the model configured on the routing step it's currently attempting. Send `"default"`, your router's slug, or anything else — it makes no functional difference. To control which model actually answers, edit the router's [routing chain](/docs/concepts/#routing-steps-fallback), not the request.

## Error format

| Status | When |
|---|---|
| `400` | No routing steps configured on the router, or every attempted step failed with a context-overflow error (request too big for every configured model) |
| `401` | Missing/invalid router API key |
| `402` | Hosted service only: router's owner has no active subscription |
| `502` | Every routing step was attempted and every one failed (non-context-overflow reasons) |
| `200` + SSE error event | Streaming request where at least one chunk was already sent to the client before every step failed — can't change the HTTP status mid-stream, so the error arrives as an SSE event in the format matching the endpoint (OpenAI/Anthropic/Responses) |

Verified: a bad API key against a running instance returns HTTP `401`.
