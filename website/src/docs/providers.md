---
title: Supported Providers
navTitle: Supported Providers
description: Every LLM provider adapter DodoRouter supports, with auth type and provider-specific notes.
section: Providers & Models
order: 9
---

# Supported providers

Responses provider usage preserves both input/cache details and output/reasoning
details through normalization. Responses clients receive those details back,
not just the three headline token counts.

Responses-format adapters preserve the client's full `reasoning` object and
explicit `parallel_tool_calls` setting. This includes Codex Responses-Lite's
`context` setting; provider-default routing does not remove client choices.

The OpenAI Codex adapter preserves non-message [Responses input items](/docs/api/responses/#typed-input-items), including `additional_tools` and tool history. This same-format preservation does not imply support for those items on other providers' API formats.

When supplied, OpenAI-compatible nested cache-write counts are normalized alongside cache reads. For the Codex Responses format, `input_tokens_details.cache_write_tokens` becomes the logged cache-write count; an explicit zero stays zero, while an absent count remains unknown. These figures feed [cache evidence](/docs/agent-access/#cache-evidence-without-prompt-access) and cost accounting.

Each row is a distinct adapter. Where a provider offers both a pay-as-you-go API and a flat-rate coding subscription, they're listed as separate key types since they use different base URLs and pricing.

| Provider | Key type(s) | Auth | Notes |
|---|---|---|---|
| OpenAI | `openai` | Bearer | GPT-4o/4.1, o1/o3, GPT-5.x |
| OpenAI Codex (ChatGPT) | `openai-codex` | OAuth (device flow, in-app) | Uses your ChatGPT plan's included usage rather than per-token billing; cost tracked as $0 |
| Anthropic | `anthropic` | x-api-key | Claude models |
| Anthropic (Claude Pro/Max) | `anthropic_oauth` | Bearer setup-token | Paste a token from `claude setup-token` (run the Claude Code CLI's own command); flat-rate, no per-token cost |
| Google Gemini | `google` | Query param | Gemini 1.5/2.x family |
| Groq | `groq` | Bearer | Fast inference on open models |
| Mistral | `mistral` | Bearer | Mistral/Codestral family |
| Cohere | `cohere` | Bearer | Command family, Cohere's v2 chat API |
| DeepSeek | `deepseek` | Bearer | deepseek-chat, deepseek-reasoner |
| Moonshot / Kimi | `moonshot` | Bearer | Pay-as-you-go API |
| Moonshot / Kimi Code | `moonshot_coding` | Bearer | Flat-rate coding subscription plan, $0 marginal cost |
| Wafer | `wafer` | Bearer | Open models (GLM, Kimi, MiniMax, Qwen) on Wafer's serverless API; OpenAI-compatible |
| xAI (Grok) | `xai` | Bearer | Grok family |
| z.ai (GLM) | `zai_standard` | Bearer | Pay-as-you-go API |
| z.ai Coding Plan | `zai_coding` | Bearer | Flat-rate coding subscription plan, $0 marginal cost |

Every adapter normalizes provider-specific quirks so the fallback chain "just works": each provider signals a context-window overflow differently (Anthropic returns a 400 with "prompt is too long" in the message; z.ai returns HTTP 200 with `finish_reason: "model_context_window_exceeded"`; OpenAI uses an explicit error code) and DodoRouter detects all of these and treats them the same way — as a fallback-eligible error, unless you've turned on ["Skip fallback on context overflow"](/docs/concepts/#routing-steps-fallback). One known exception: Wafer reports an overflow with the same generic 400 it uses for any invalid request, so DodoRouter can't tell them apart — an oversized request on a Wafer step still falls back to the next step, but it isn't recognized as an overflow specifically, so the skip-fallback option doesn't apply to it. Cache-token reporting (for cost and cache-hit-rate tracking) is likewise normalized across each provider's own field names.
