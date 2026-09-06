---
title: Models & Pricing
description: How DodoRouter syncs model capabilities and pricing, and how subscription keys are costed.
section: Providers & Models
order: 10
---

# Models & pricing

For Responses routes, a step's provider-default reasoning setting injects
nothing. Reasoning fields supplied by the client still pass through unchanged;
the provider decides only when the client also leaves the setting unspecified.

Model availability is separate from client-format compatibility. Codex sessions containing native typed Responses items need an upstream that supports those items; selecting a model on a different API format does not guarantee its tool history can be translated. See [typed Responses input](/docs/api/responses/#typed-input-items).

Cache read/write usage comes from provider reports, including nested OpenAI-compatible `cache_write_tokens`. Reported writes participate in cost estimates using the catalog's cache-write price; a missing write count is not assumed to be zero in diagnostic evidence.

DodoRouter syncs a model catalog from [models.dev](https://models.dev), an open model database, giving you context-window size, per-million-token pricing (input, output, cache read, cache write), capability flags (vision, function calling, prompt caching, etc.), and which reasoning effort levels a model actually accepts. This is what powers the model dropdown when you add a routing step — pick a known model and DodoRouter already knows its limits and price, or choose **Custom…** to type any model id it doesn't have listed yet (it'll still route correctly; you just won't get cost estimation for an unknown model).

Subscription-based keys (`openai-codex`, `anthropic_oauth`, `moonshot_coding`, `zai_coding`) are costed at $0/token in the dashboard — you're already paying a flat monthly fee for that usage, so DodoRouter shows requests through them as "included in plan" rather than computing a per-token dollar amount.
