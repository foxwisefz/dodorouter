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

## Logs

Every request, live-streamed in as it happens. Filter by router or favorites. Each log opens into full detail: conversation view, raw request/response JSON, per-attempt fallback trace, timing, cost, and a **Replay** action that reruns the same conversation against a different model and diffs the two results (inline diff, side-by-side, or raw JSON).

## Sessions & Recordings

Reached from a router's page. [Sessions](/docs/concepts/#sessions) group requests by your `x-session-id` header; [Recordings](/docs/concepts/#recordings) are explicit start/stop capture windows started from the dashboard or the [recordings API](/docs/api/#endpoints). Both give you a scoped log list with their own stat tiles (requests, tokens, avg latency, success rate).
