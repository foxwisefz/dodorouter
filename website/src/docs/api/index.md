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
