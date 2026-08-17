---
title: Dashboard Guide
description: A tour of every page in the DodoRouter web dashboard.
section: Dashboard
order: 11
---

# Dashboard guide

Everything below lives in the left sidebar once you're logged in.

## Dashboard

A live, auto-refreshing (every 5s) overview for whichever router you select: request volume over the last hour, success rate, p95 latency, token usage, cache-hit rate, the router's routing chain at a glance, and a recent-requests table.

## Routers

Create/rename/delete routers, and open a router's own page — which is where you'll spend most of your setup time. On a router's page you get: a live-updating "Connect" panel with ready-to-copy code snippets (cURL / Python / Node, in whichever of the three API formats you pick), the routing-chain editor (add steps, reorder them with up/down arrows, assign a specific provider key per step, toggle context-overflow behavior), recent logs, and a setup checklist that walks you through the four things a router needs before it can serve a request: a provider key, a routing step, a key assigned to that step, and a first request.

## Providers

Add/rename/delete provider API keys, grouped by provider. Each key shows a live status badge — verified valid (green), invalid (red), out of quota (amber), or not-yet-verified (click to check) — so a routing step referencing a broken key is visibly flagged before you find out the hard way in production.

## API Keys

One card per router showing its endpoint URL and masked key prefix, with a one-click **Regenerate** (old key stops working immediately; new one is shown once).

## Agent Activity

What coding agents connected over [MCP](/docs/agent-access/) have been doing with your traffic. There is nothing to create here — agents connect over OAuth and you approve them in the browser — so the page is the record: which agents are connected, how many calls each made, which of them actually read prompt and response text, and every individual call filterable by allowed / denied / errored. Refused calls are recorded too, which is what makes the page worth reading.

## Logs

Every request, live-streamed in as it happens. Filter by router or favorites. Each log opens into full detail: conversation view, raw request/response JSON, per-attempt fallback trace, timing, cost, and a **Replay** action that reruns the same conversation against a different model and diffs the two results (inline diff, side-by-side, or raw JSON).

The log page also shows a **Context breakdown**: input tokens bucketed by what the context was made of — system prompt, tool definitions, history, tool results (split per tool), pasted file contents — and how much of each sat in the cacheable prefix. "Tool results are 60% of this request's tokens, mostly one `Read`, and they sit after the cache breakpoint" is the sentence that tells you what to trim. Shares are allocated pro-rata against the billed total (no provider publishes its tokenizer), so trust the percentages and treat per-bucket absolutes as estimates. The same breakdown rides `get_log` and, summed per session, `get_session` on [agent access](/docs/agent-access/).

## Sessions & Recordings

Reached from a router's page. [Sessions](/docs/concepts/#sessions) group requests by your `x-session-id` header; [Recordings](/docs/concepts/#recordings) are explicit start/stop capture windows started from the dashboard or the [recordings API](/docs/api/#endpoints). Both give you a scoped log list with their own stat tiles (requests, tokens, avg latency, success rate).

A recording's page also carries **Benchmark this recording**: one click turns the capture into an [evaluation](#evaluations) whose source set is the recording's replayable requests — evenly sampled across the capture when more than 20 qualify, so the sample isn't biased toward how a session starts. Benchmarks created this way are listed back on the recording's page, so the capture and the verdicts measured on it stay together.

## Evaluations

**Evaluations** (in the sidebar) benchmarks candidate models against requests your router actually served: each candidate model re-answers the source request(s), a judge model you pick scores every answer against your rubric, and the results page ranks candidates by average score, consistency (std dev), latency and cost — including a quality-versus-price scatter with the Pareto frontier marked.

Start one from any log page ("Evaluate"), from a recording ("Benchmark this recording" — the strongest basis, since the sample is production traffic nobody hand-picked), or let a connected coding agent drive the whole loop over [agent access](/docs/agent-access/). A benchmark built on several source logs aggregates its ranking across all of them, so the score answers "on my traffic", not "on this one request" — and each ranking row expands into a per-request breakdown, worst first, because an average can hide a model that is fine on 18 of 20 requests and catastrophic on 2.

The builder's **Prompt variants** step holds the model constant and varies the request instead: name a variant and give it a system prompt, and every candidate answers every variant against the same rubric and judge, ranked one row per model × variant. A variant left without a system prompt replays the request exactly as served, so your current prompt sits in the comparison under its own name. Variants multiply the run count, and the run plan says so before you start.

You author a variant against the request, not from memory. **Request as served** lists every message of the source request, numbered; **Start from served prompt** drops the real system prompt into the variant so you edit it rather than retype it; and as you type, a diff under the box shows exactly what your version changes. **Message patches** work the same way: pick the message you want to replace from a list of the request's own messages, its text opens for editing, and the diff shows the transform — compress a tool result, hold everything else frozen, and the benchmark answers whether the reasoning survived. On a recording, the picker shows the first sampled request and the same position is patched in all of them, so an index that a shorter sampled request doesn't have is refused when you save, not minutes into the spend.

For recorded agent traffic, the judge framing **Next action** (in the evaluation builder) asks a sharper question than answer quality: at each captured decision point, the candidate proposes one next move against the same frozen history — every real tool result included, nothing simulated — and the judge states whether it beats what production actually did. The rankings then carry a **Vs production** column: "better-or-equal move in N% of decisions".

A recording-based benchmark also projects each candidate's cost onto the capture's real request rate: "as served, this traffic projects to $B/month; this candidate would be $X/month" — at API list prices, judge spend excluded. The projection only appears when the capture spans at least 10 minutes; a rate measured more briefly says more about when you clicked stop than about your traffic.

Evaluations are immutable — a changed rubric or candidate list is a new evaluation (use **Duplicate**), so past scores always mean what they meant. Failed runs can be retried without re-paying for answers already generated, and a running benchmark can be cancelled mid-flight.

When a verdict holds, **Route here** on a ranking row applies it: the routing step that served the benchmark's incumbent is updated to the winning candidate (provider, key and model change; temperature, token limits and reasoning effort stay as you set them — the benchmark didn't measure changing those). Every applied change is recorded against the benchmark batch that justified it and listed on the evaluation page, where one click reverts it. If routing has been edited since the benchmark ran and no step unambiguously serves the incumbent anymore, the apply refuses and tells you to edit the step directly rather than guessing.

A downgrade decision is only valid for the traffic it was measured on, so an applied change offers **Keep honest**: the same rubric and judge score a few live answers a day (judge cost only — the answers were already served), and when the rolling live average sits below the benchmark baseline for two sweeps in a row the evaluation raises a *below baseline* alert. The alert clears on its own when scores recover, and monitoring can be paused any time.
