---
title: Codex CLI
description: Add DodoRouter as a custom model_providers entry in ~/.codex/config.toml.
order: 16
---

# Codex CLI

OpenAI's Codex CLI supports custom model providers in `~/.codex/config.toml`:

```toml
model = "default"
model_provider = "dodorouter"

[model_providers.dodorouter]
name = "DodoRouter"
base_url = "{base_url}/r/{router}/v1"
env_key = "DODO_API_KEY"
```

`env_key` names an environment variable Codex reads the API key from, so the key itself never has to live in the config file:

```bash
export DODO_API_KEY="sk-dodo-YOUR_KEY"
codex exec "Reply with exactly the single word: pong"
```

Verified: Codex CLI's default streaming mode renders the response live in the terminal (`codex` then `pong`), and DodoRouter's own logs confirm the underlying completion (`"pong"`, `finish_reason: "stop"`, HTTP 200, tokens billed correctly). An earlier version of DodoRouter's streamed [Responses API](/docs/api/responses/) didn't emit the item-lifecycle events Codex CLI's client strictly requires before a text delta, which caused it to log `OutputTextDelta without active item` and stall — that's now fixed. All four integrations in this section are clean.
