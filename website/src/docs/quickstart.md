---
title: Quickstart (hosted)
navTitle: Quickstart
description: Register, create a router, add a provider key, and send your first request against the hosted service.
section: Get Started
order: 2
---

# Quickstart (hosted)

This walks through the exact steps on the hosted instance at `api.dodorouter.com`. Everything here also works identically on a [self-hosted](/docs/self-hosting/) instance — just swap the base URL.

## 1. Create an account

Go to [api.dodorouter.com/users/register](https://api.dodorouter.com/users/register) and enter your email. DodoRouter uses passwordless, magic-link login: there's no password to set at this step, just an email address and agreement to the Terms of Service.

DodoRouter emails you a one-time login link. Open it and click **Continue to DodoRouter** — this both confirms your account and logs you in. (If you'd rather use a password day-to-day, you can set one later under **Settings**; magic-link login keeps working either way.)

## 2. Create a router

On first login you're dropped straight into **New Router**. Give it a name (e.g. `my-agent`) — a URL-safe slug is derived from it automatically. Saving generates your router's API key, shown **once** in a banner. Copy it now; DodoRouter only ever stores a salted hash, so if you lose it you'll need to regenerate a new one from the **API Keys** page (which invalidates the old one).

## 3. Add a provider API key

Go to **Providers**, pick a provider (e.g. OpenAI or Anthropic), click **Add Key**, and paste in your API key from that provider. DodoRouter verifies it in the background and shows a green check once confirmed valid.

## 4. Add a routing step

Open your router, and under **Routing Chain** click **Add Step**. Choose the provider, then the model (pick from the list, synced from live provider catalogs, or choose **Custom…** to type an exact model id). Add a second and third step with different providers if you want automatic fallback — that's the whole point.

## 5. Send your first request

Use the router's API key as a Bearer token. The `model` value you send doesn't matter — DodoRouter always uses whatever model is configured on the routing step — so `"default"` is a fine placeholder.

```bash
curl https://api.dodorouter.com/r/my-agent/v1/chat/completions \
  -H "Authorization: Bearer sk-dodo-YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

Verified response shape (this exact request was run against a live DodoRouter instance):

```json
{
  "choices": [{
    "finish_reason": "stop",
    "index": 0,
    "message": { "content": "Hello! How can I help you today?", "role": "assistant" }
  }],
  "model": "gpt-5.5",
  "usage": { "completion_tokens": 10, "prompt_tokens": 13, "total_tokens": 23,
             "prompt_tokens_details": { "cached_tokens": 0 } }
}
```

Every request also gets logged in real time under **Logs**, with full request/response bodies, timing breakdown, token usage, and cost.
