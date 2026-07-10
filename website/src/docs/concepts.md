---
title: Core Concepts
description: Routers, routing steps and fallback, provider keys vs router keys, plan types, reasoning effort, sessions, recordings, and logs.
section: Core Concepts
order: 4
---

# Core concepts

## Routers

A router is the unit a client connects to. Each has a unique slug (used in the URL path), its own API key, and its own routing chain. Most people create one router per application or environment (e.g. `my-agent-prod`, `my-agent-staging`), since the routing chain, session grouping, and logs are all scoped per router.

## Routing steps & fallback

Each router has an ordered list of steps. A step is: provider + model, optionally a temperature/max_tokens override, a reasoning-effort level, and which of your provider keys to use. DodoRouter tries step 1 first. If it fails with an error class that's safe to retry — rate limited, server error, timeout, auth error, model unavailable, or context overflow — it moves to the next step, carrying over any partial content a streaming provider had already produced so the next provider continues rather than starting over. It gives up and returns an error only once every step has failed.

There's one router-level toggle that changes this: **"Skip fallback on context overflow"**. Off by default (a request too big for step 1 tries step 2, which might have a bigger context window). Turn it on if you'd rather fail fast on oversized requests than silently burn quota retrying them against every provider in the chain.

## Provider keys vs. router API keys

These are two different kinds of key and it's easy to mix them up:

- **Provider keys** (Providers page) — your upstream credentials: an OpenAI key, an Anthropic key, a z.ai key, etc. DodoRouter uses these to call the actual LLM provider. You attach one to each routing step.
- **Router API keys** (API Keys page) — the key *your* client uses to call DodoRouter itself, in the form `sk-dodo-…`. One per router. Regenerating it immediately invalidates the old one.

## Plan types: standard vs. coding subscriptions

z.ai and Moonshot (Kimi) both offer a flat-rate "coding" subscription plan alongside their regular pay-as-you-go API, each with its own base URL and, for cost tracking, $0 marginal per-token pricing. When adding a routing step for these providers, you'll see both a standard key option and a "coding" one; pick whichever matches the credential you added on the Providers page.

## Reasoning effort

Reasoning models expose "how hard to think" differently per provider — a string like `reasoning_effort` for OpenAI, a token budget for Anthropic extended thinking, a thinking budget for Gemini, or a plain on/off toggle for DeepSeek/z.ai/Moonshot-style models. Set a canonical level per routing step — `none, minimal, low, medium, high, xhigh, max` — and DodoRouter translates it into whatever the upstream provider actually expects. If your client already sends its own reasoning parameter in the request, that always wins over the routing step's default.

## Sessions

Sessions group related requests (e.g. every call in one coding-agent conversation) under a shared id, purely for the Logs UI — DodoRouter doesn't use sessions for routing decisions. Send an `X-Session-Id` header (and optionally `X-Session-Name` for a human-readable label) with each request, and they'll show up grouped under **Sessions** on that router. The header name is configurable per router (Router → Edit → "Session header", default `x-session-id`) — useful if a client library already sends its own conversation-id header under a different name and you'd rather reuse that than add a new one.

## Recordings

A recording is an explicit start/stop capture window, separate from sessions — useful for bracketing "everything that happened during this one debugging run" or a scripted test, regardless of session id. Start one from the dashboard or via `POST /recordings/start`, make your requests, stop it, then review exactly that batch under Recordings.

## Logs & replay

Every proxied request is logged with full request/response bodies (large payloads are truncated for storage, flagged as such), token usage, cost, latency breakdown (total / provider time / TTFB / upload), and the full fallback trace if more than one step was attempted. From any log you can **Replay** the same conversation against a different provider/model/reasoning-effort and get a side-by-side diff — handy for "would a cheaper model have handled this the same way?" comparisons.
