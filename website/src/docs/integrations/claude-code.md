---
title: Claude Code
description: Point Claude Code at DodoRouter via ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN.
order: 13
---

# Claude Code

Claude Code talks the Anthropic Messages API, so point it at your router's `/v1/messages`-serving base and pass your DodoRouter key as the auth token:

```bash
export ANTHROPIC_BASE_URL="{base_url}/r/{router}"
export ANTHROPIC_AUTH_TOKEN="sk-dodo-YOUR_KEY"
claude
```

Verified: `claude -p "Reply with exactly the single word: pong"` with the env vars above returned `pong`. Since [DodoRouter ignores the requested model](/docs/api/#the-model-field-is-ignored), Claude Code will actually run whatever provider/model your routing chain resolves to first — including non-Anthropic models — while still speaking Anthropic's wire format to Claude Code itself. This is also how you route Claude Code's usage through a fallback chain for reliability, even if every step in that chain is Claude models via different keys.

To make this permanent for a project, add the same two variables to that project's `.claude/settings.json` under an `"env"` key instead of exporting them in your shell.
