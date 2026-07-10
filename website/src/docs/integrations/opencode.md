---
title: OpenCode
description: Add DodoRouter as a custom OpenAI-compatible provider in opencode.jsonc.
order: 14
---

# OpenCode

OpenCode's provider system supports any OpenAI-compatible endpoint via the `@ai-sdk/openai-compatible` package. Add a custom provider to `opencode.jsonc` (either project-local or `~/.config/opencode/opencode.jsonc` for all projects):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "dodorouter": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "{base_url}/r/{router}/v1",
        "apiKey": "sk-dodo-YOUR_KEY"
      },
      "models": {
        "default": { "name": "DodoRouter" }
      }
    }
  }
}
```

Then run it against that provider/model:

```bash
opencode run -m dodorouter/default "Reply with exactly the single word: pong"
```

Verified: returned `pong`. The model key (`default` above) can be any label — it isn't sent upstream as a real model id, since DodoRouter substitutes whatever the routing chain resolves to. Add more entries under `"models"` if you want several OpenCode-visible "models" that all point at the same DodoRouter provider but happen to carry different display names.
