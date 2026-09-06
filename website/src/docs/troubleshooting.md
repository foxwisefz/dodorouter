---
title: Troubleshooting & FAQ
navTitle: Troubleshooting & FAQ
description: Common errors and questions, and what actually causes each one.
section: Operations
order: 19
---

# Troubleshooting & FAQ

### Codex shows zero cache reads while Dodo's logs show hits

Earlier Responses egress returned only input/output/total tokens, dropping
`input_tokens_details.cached_tokens`. It also omitted output reasoning details.
The formatter now restores both detail objects. Update DodoRouter if the final
`response.completed` usage omits details present in the provider's usage.

### Codex resume: `content[0].text` received an array

Earlier Responses conversion wrapped structured assistant output blocks inside
`output_text.text`, which must be a string. Assistant content arrays now remain
arrays of blocks. This fixes a case where a single-turn smoke test passed but
the next turn of the same session failed.

### Codex Responses-Lite requires `reasoning.context` to be `all_turns`

Earlier Responses ingress kept only the client's reasoning effort, losing
`context` while forwarding the Responses-Lite header. The full client reasoning
object now survives conversion. Update DodoRouter if this field disappears
between the incoming and outbound requests; do not strip the header or hardcode
context as a workaround. Provider-default routing does not erase client settings.

### Codex: `input[0].content` is null

Earlier DodoRouter versions treated Codex's `additional_tools` input item as a
normal developer message, replacing its type and tools with `content: null`.
The Responses conversion now preserves non-message typed input items. If the
outbound request shows this corruption, update DodoRouter; do not work around it
by deleting the client's tools or inserting empty text.

Inspect each attempt in the request's Trace: the last fallback's error can be
different from the initial provider's rejection. A final `developer`-role error
does not explain an earlier Responses `invalid_type` error. A fallback to a
different API format may still be incompatible with native Responses items.

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

### Why did my prompt cache stop hitting?

Open the diverging request's **Cache evidence** or read `get_log.cache_diagnosis` through MCP. `prefix_changed` names the first changed component and one-based item index (tools, system prompt, or conversation message); breakpoint changes are reported separately. The signatures contain no prompt text or tool names and survive body truncation/removal. They identify a structural change, not a proven provider cache invalidation.

With an unchanged shared prefix, `cache_expired` means the gap exceeded a uniform, explicitly requested TTL (likely); `parallel_race` means the compared request overlapped this one (possible). `provider_no_hit` means zero reported cache-read tokens with no structural difference found, not a confirmed provider defect. `unknown` covers missing baselines, routing changes, and parameter changes whose cache effects are unknown. Missing cache usage is `unreported`, never an assumed zero.

The comparison sees only completed logs available when this row was written. It cannot see provider shards, exact expiry, all concurrent requests, or external traffic; it does not invent a `different_shard` diagnosis. Mixed or omitted TTLs do not establish an expiry. Concurrent or forked traffic sharing a session may compare unrelated turns; diagnostics use only the session ID the client already supplies. Sessionless global prefix lookup and exact token-offset localization are not included.
