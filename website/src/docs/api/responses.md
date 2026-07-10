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

## Streaming event sequence

With `"stream": true`, DodoRouter emits the full item lifecycle a strict Responses-API client expects:

`response.created` → `response.output_item.added` → `response.content_part.added` → one or more `response.output_text.delta` → `response.output_text.done` → `response.content_part.done` → `response.output_item.done` → `response.completed`.

Verified with a real [Codex CLI](/docs/integrations/codex-cli/) streaming run — text renders live in the terminal. An earlier version of this endpoint skipped the `output_item.added` / `content_part.added` events, which caused strict clients to log `OutputTextDelta without active item` and stall; that gap is fixed.
