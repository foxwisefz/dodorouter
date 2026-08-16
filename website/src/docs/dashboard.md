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

## Sessions & Recordings

Reached from a router's page. [Sessions](/docs/concepts/#sessions) group requests by your `x-session-id` header; [Recordings](/docs/concepts/#recordings) are explicit start/stop capture windows started from the dashboard or the [recordings API](/docs/api/#endpoints). Both give you a scoped log list with their own stat tiles (requests, tokens, avg latency, success rate).

A recording's page also carries **Benchmark this recording**: one click turns the capture into an [evaluation](#evaluations) whose source set is the recording's replayable requests — evenly sampled across the capture when more than 20 qualify, so the sample isn't biased toward how a session starts. Benchmarks created this way are listed back on the recording's page, so the capture and the verdicts measured on it stay together.

## Evaluations

**Evaluations** (in the sidebar) benchmarks candidate models against requests your router actually served: each candidate model re-answers the source request(s), a judge model you pick scores every answer against your rubric, and the results page ranks candidates by average score, consistency (std dev), latency and cost — including a quality-versus-price scatter with the Pareto frontier marked.

Start one from any log page ("Evaluate"), from a recording ("Benchmark this recording" — the strongest basis, since the sample is production traffic nobody hand-picked), or let a connected coding agent drive the whole loop over [agent access](/docs/agent-access/). A benchmark built on several source logs aggregates its ranking across all of them, so the score answers "on my traffic", not "on this one request" — and each ranking row expands into a per-request breakdown, worst first, because an average can hide a model that is fine on 18 of 20 requests and catastrophic on 2.

A recording-based benchmark also projects each candidate's cost onto the capture's real request rate: "as served, this traffic projects to $B/month; this candidate would be $X/month" — at API list prices, judge spend excluded. The projection only appears when the capture spans at least 10 minutes; a rate measured more briefly says more about when you clicked stop than about your traffic.

Evaluations are immutable — a changed rubric or candidate list is a new evaluation (use **Duplicate**), so past scores always mean what they meant. Failed runs can be retried without re-paying for answers already generated, and a running benchmark can be cancelled mid-flight.
