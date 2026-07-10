---
title: Messages (Anthropic format)
navTitle: Messages (Anthropic)
description: The Anthropic-compatible messages endpoint — request, verified response, and how it powers Claude Code with non-Anthropic models.
order: 7
---

# Messages (Anthropic format)

Full bidirectional conversion, including tool_use / tool_result blocks, system prompts (string or block array, with `cache_control` preserved), and multi-block content.

```bash
curl {base_url}/r/{router}/v1/messages \
  -H "Authorization: Bearer sk-dodo-YOUR_KEY" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-5",
    "max_tokens": 100,
    "messages": [{"role": "user", "content": "Reply with exactly the word: pong"}]
  }'
```

Verified live response:

```json
{
  "id": "msg_5a8d090908f8feb21be52ef0", "type": "message", "role": "assistant",
  "content": [{"type": "text", "text": "pong"}],
  "model": "gpt-5.5", "stop_reason": "end_turn", "stop_sequence": null,
  "usage": {"input_tokens": 13, "output_tokens": 5}
}
```

Note the `model` in the response is whatever the winning routing step actually used (`gpt-5.5` here) — not the `claude-sonnet-4-5` requested, consistent with [the model field being ignored](/docs/api/#the-model-field-is-ignored). This is exactly how you'd point [Claude Code](/docs/integrations/claude-code/) at non-Anthropic models through DodoRouter.
