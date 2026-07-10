---
title: Chat Completions (OpenAI format)
navTitle: Chat Completions
description: The OpenAI-compatible chat/completions endpoint — request, verified response, and streaming.
order: 6
---

# Chat Completions (OpenAI format)

```bash
curl {base_url}/r/{router}/v1/chat/completions \
  -H "Authorization: Bearer sk-dodo-YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "stream": false,
    "messages": [{"role": "user", "content": "Reply with exactly the word: pong"}]
  }'
```

Verified live response:

```json
{
  "choices": [{"finish_reason": "stop", "index": 0,
               "message": {"content": "pong", "role": "assistant"}}],
  "model": "gpt-5.5",
  "usage": {"completion_tokens": 5, "prompt_tokens": 13, "total_tokens": 18,
            "prompt_tokens_details": {"cached_tokens": 0}}
}
```

## Streaming

With `"stream": true`, the response is a standard OpenAI-style SSE stream of `chat.completion.chunk` deltas terminated by `data: [DONE]` — verified working, including tool-call streaming.
