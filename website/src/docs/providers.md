---
title: Supported Providers
navTitle: Supported Providers
description: Every LLM provider adapter DodoRouter supports, with auth type and provider-specific notes.
section: Providers & Models
order: 9
---

# Supported providers

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
| xAI (Grok) | `xai` | Bearer | Grok family |
| z.ai (GLM) | `zai_standard` | Bearer | Pay-as-you-go API |
| z.ai Coding Plan | `zai_coding` | Bearer | Flat-rate coding subscription plan, $0 marginal cost |

Every adapter normalizes provider-specific quirks so the fallback chain "just works": each provider signals a context-window overflow differently (Anthropic returns a 400 with "prompt is too long" in the message; z.ai returns HTTP 200 with `finish_reason: "model_context_window_exceeded"`; OpenAI uses an explicit error code) and DodoRouter detects all of these and treats them the same way — as a fallback-eligible error, unless you've turned on ["Skip fallback on context overflow"](/docs/concepts/#routing-steps-fallback). Cache-token reporting (for cost and cache-hit-rate tracking) is likewise normalized across each provider's own field names.
