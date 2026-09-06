---
title: Responses API
navTitle: Responses API
description: The Responses API endpoint used by Codex-style clients — request, streaming event sequence, and verified response.
order: 8
---

# Responses API

Used by Codex-style clients. Both sync and streaming are supported and verified:

```bash
curl {base_url}/r/{router}/v1/responses \
  -H "Authorization: Bearer sk-dodo-YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "default", "input": "Reply with exactly the word: pong"}'
```

## Typed input items

Responses usage includes reported `input_tokens_details` (including cached
tokens) and `output_tokens_details` (including reasoning tokens). These details
survive provider normalization and the final `response.completed` event as well
as synchronous responses. Reported zero remains zero; missing details are not
invented.

Assistant message content arrays also retain their output blocks on resumed
sessions; arrays are not wrapped inside a string-valued `text` field.

The client's full `reasoning` object is preserved on Responses upstreams,
including `context`, `summary` and `effort`. A routing step set to provider
default does not inject an effort or context value. Client-supplied reasoning
still passes through; if both client and step omit it, the provider decides.
Explicit `parallel_tool_calls` values also survive the round-trip, including
`false`, which Codex Responses-Lite requires.

On Responses-format upstream routes (including OpenAI Codex), non-message
`input` items retain their type, payload and order. This includes Codex
`additional_tools`, reasoning items, function calls and function-call outputs.
An item's `role` does not make it a message: `additional_tools` can have a
`developer` role without a `content` field, and DodoRouter must not fabricate
`content: null` for it. Ordinary messages still use the message conversion path.

This preserves the request representation; the selected upstream must still
support the item types. It does not add translations of these native items for
Chat Completions, Anthropic or Gemini fallback routes.

## Streaming event sequence

With `"stream": true`, DodoRouter emits the full item lifecycle a strict Responses-API client expects:

`response.created` → `response.output_item.added` → `response.content_part.added` → one or more `response.output_text.delta` → `response.output_text.done` → `response.content_part.done` → `response.output_item.done` → `response.completed`.

Verified with a real [Codex CLI](/docs/integrations/codex-cli/) streaming run — text renders live in the terminal. An earlier version of this endpoint skipped the `output_item.added` / `content_part.added` events, which caused strict clients to log `OutputTextDelta without active item` and stall; that gap is fixed.
