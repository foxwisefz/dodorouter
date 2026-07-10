---
title: Forge
description: Configure Forge's built-in openai_compatible provider to point at DodoRouter.
order: 15
---

# Forge

Forge has a built-in `openai_compatible` provider slot. The easiest path is the interactive menu:

```bash
forge provider login
# choose "openai_compatible", then enter your base URL and API key when prompted
```

This writes an entry to `~/.forge/.credentials.json` shaped like this (confirmed from a real, already-configured Forge installation pointed at DodoRouter):

```json
{
  "id": "openai_compatible",
  "auth_details": { "api_key": "sk-dodo-YOUR_KEY" },
  "url_params": { "OPENAI_URL": "{base_url}/r/{router}/v1" }
}
```

and sets in `~/.forge/.forge.toml`:

```toml
[session]
provider_id = "openai_compatible"
model_id = "default"
```

Then run `forge` as usual, or non-interactively with `forge -p "your prompt"`.

<div class="docs-callout docs-callout-warn my-2">
  <p class="docs-callout-title">Verified with a caveat</p>
  <p>We pointed a real Forge installation at a live DodoRouter router using exactly this config and it connected, authenticated, and completed several successful tool-calling turns (each logged by DodoRouter as HTTP 200 with the correct content). During one longer automated run, Forge's own client logged "Empty completion received" and retried repeatedly on a turn where DodoRouter's logs show it actually returned a perfectly valid response (right content, <code>finish_reason: "stop"</code>). That looks like an intermittent client-side parsing hiccup in Forge rather than anything DodoRouter did wrong, and it's exactly the config the project's own maintainers run day-to-day against the hosted service — but if you hit a similar stall, check the request in DodoRouter's <a href="/docs/dashboard/">Logs</a> before assuming the request failed.</p>
</div>
