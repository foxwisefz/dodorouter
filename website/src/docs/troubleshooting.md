---
title: Troubleshooting & FAQ
navTitle: Troubleshooting & FAQ
description: Common errors and questions, and what actually causes each one.
section: Operations
order: 19
---

# Troubleshooting & FAQ

### "No routing configured for router '…'"

The router has zero routing steps. Add at least one on the router's page under Routing Chain.

### "Failed to store API key securely" when adding a provider key

Self-hosted only: `INFISICAL_TOKEN` / `INFISICAL_PROJECT_ID` aren't set or are invalid. See the callout in [Self-hosting](/docs/self-hosting/).

### 401 Invalid API key

You're using a provider key (from the Providers page) where a router API key is expected, or vice versa — see [Provider keys vs. router API keys](/docs/concepts/#provider-keys-vs-router-api-keys). Also check you didn't regenerate the router's key since your client last read it.

### 401 on `/mcp`, even with a valid router key

The MCP endpoint doesn't take a router API key at all — that key sends traffic, and reading traffic back is a separate grant. Connect the agent over OAuth instead: `claude mcp add --transport http dodorouter {base_url}/mcp`, then approve it in the browser. See [Agent access](/docs/agent-access/).

### 402 Payment Required

Hosted service only: the account owning this router doesn't have an active subscription. Visit Billing to subscribe. Doesn't apply to self-hosted instances unless you've configured Stripe billing yourself.

### 400 "Input exceeds context window of this model"

Every routing step failed with a context-overflow error — either you only have one step and its model's context window is too small, or you've enabled ["Skip fallback on context overflow"](/docs/concepts/#routing-steps-fallback) and the first step alone couldn't fit the request. Add a step with a larger context window, or disable that toggle so DodoRouter tries the rest of the chain.

### 502 "All providers failed"

Every step in the chain returned a non-recoverable error. Open the request in Logs → it shows the per-step error for each attempt, which is almost always more specific than the top-level message.

### A routing step shows "invalid" or "out of credits" next to its assigned key

DodoRouter tracks key health from real dispatch outcomes. Fix or replace the key on the Providers page; the warning links straight there.

### Do I need to send a real model name?

No — see [The model field is ignored](/docs/api/#the-model-field-is-ignored). DodoRouter always uses the model configured on the routing step it's attempting.
