---
title: Overview
description: What DodoRouter is, how a request flows through it, and where to go next.
section: Get Started
order: 1
---

# DodoRouter docs

DodoRouter is an LLM proxy and router. Point any OpenAI-, Anthropic-, or Responses-API client at it once, and it forwards your requests through a fallback chain of providers you configure — retrying the next provider automatically on rate limits, outages, or context overflows — while logging every request.

<div class="docs-callout my-2">
  <p class="docs-callout-title">🤖 Reading this with an AI agent?</p>
  <p>Fetch <code>https://dodorouter.com/llms.txt</code> for a condensed, link-based index, or <code>https://dodorouter.com/llms-full.txt</code> for every page on this site concatenated as one plain-Markdown file. Every individual page also has a raw-Markdown twin at its own URL with <code>.md</code> appended — e.g. <code>https://dodorouter.com/docs/quickstart.md</code> — so an agent can fetch just the page it needs.</p>
</div>

## Jump in

<div class="grid sm:grid-cols-2 gap-3 my-2">
  <a href="/docs/quickstart/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Quickstart →</p>
    <p class="text-xs text-muted-foreground">Register, create a router, send your first request. ~5 minutes.</p>
  </a>
  <a href="/docs/self-hosting/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Self-hosting →</p>
    <p class="text-xs text-muted-foreground">Clone, configure, and run your own instance.</p>
  </a>
  <a href="/docs/api/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">API reference →</p>
    <p class="text-xs text-muted-foreground">Endpoints, auth, request/response formats, errors.</p>
  </a>
  <a href="/docs/integrations/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Connect a coding agent →</p>
    <p class="text-xs text-muted-foreground">Claude Code, OpenCode, Forge, Codex CLI — verified configs.</p>
  </a>
  <a href="/docs/agent-access/" class="docs-card block rounded-xl border border-border p-4 hover:border-accent transition-colors">
    <p class="text-sm font-semibold text-foreground mb-1">Agent access (MCP) →</p>
    <p class="text-xs text-muted-foreground">Let an agent read your traffic and benchmark models on it, over OAuth.</p>
  </a>
</div>

## How a request flows

A DodoRouter deployment has one account, any number of **routers**, and a pool of **provider keys** (your OpenAI, Anthropic, z.ai, Moonshot, etc. credentials). Each router has its own DodoRouter API key and its own ordered list of **routing steps** — ordered pairs of (provider, model) that DodoRouter tries in sequence.

Your client (a script, an SDK, or a coding-agent CLI like Claude Code) talks to DodoRouter using a completely standard OpenAI or Anthropic request. DodoRouter ignores the `model` field you send and instead dispatches to routing step 1. If that provider call fails in a way that's safe to retry (rate limit, 5xx, timeout, context overflow, auth error), DodoRouter automatically moves to step 2, then step 3, and so on, only returning an error once every step has failed. The response is converted back to the format your client expects, so the client never has to know which provider actually served the request.

```
your client → DodoRouter (/r/{router}/v1/...)
    → step 1: provider A / model X   ✗ 429 rate limited
    → step 2: provider B / model Y   ✓ 200 success
← response, converted back to your client's format
```

DodoRouter is a Phoenix (Elixir) application. It ships as a hosted service at [api.dodorouter.com](https://api.dodorouter.com) and as self-hostable open source at [github.com/foxwise-ai/dodorouter](https://github.com/foxwise-ai/dodorouter).
