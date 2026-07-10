---
title: Connect a Coding Agent
navTitle: Overview
description: Point Claude Code, OpenCode, Forge, or Codex CLI at DodoRouter — verified configs for each.
order: 12
---

# Connect a coding agent

Every configuration in this section was actually run against a live DodoRouter instance — not copied from each tool's generic docs. Replace `sk-dodo-YOUR_KEY` and the router slug with your own in each example.

<div class="grid sm:grid-cols-2 gap-3 my-2">
  <a href="/docs/integrations/claude-code/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Claude Code →</p>
    <p class="text-xs text-muted-foreground">Two environment variables, verified clean.</p>
  </a>
  <a href="/docs/integrations/opencode/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">OpenCode →</p>
    <p class="text-xs text-muted-foreground">Custom OpenAI-compatible provider, verified clean.</p>
  </a>
  <a href="/docs/integrations/forge/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Forge →</p>
    <p class="text-xs text-muted-foreground">Built-in openai_compatible provider slot.</p>
  </a>
  <a href="/docs/integrations/codex-cli/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Codex CLI →</p>
    <p class="text-xs text-muted-foreground">Custom model_providers entry, verified clean.</p>
  </a>
</div>

All four talk to DodoRouter using one of the three [API formats](/docs/api/) — Anthropic Messages, an OpenAI-compatible provider package, or the Responses API — and all four are unaffected by [the model field being ignored](/docs/api/#the-model-field-is-ignored): whatever your routing chain resolves to is what actually answers, regardless of what model name the client thinks it's talking to.
