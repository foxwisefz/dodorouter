---
title: Agent Access (MCP)
navTitle: Agent Access (MCP)
description: Let a coding agent read your router's traffic and benchmark models on it, over MCP with OAuth — no key pasted into a config file.
section: Agent Access
order: 17
---

# Agent access over MCP

The rest of these docs are about sending traffic *through* DodoRouter. This page is about the other direction: letting a coding agent read that traffic back, so it can answer questions you would otherwise answer by hand.

> "This support-reply call costs $0.011 and uses Claude Opus. Would Haiku be good enough? Would Kimi?"

An agent connected here picks a request your product **really made**, replays it against whichever models you want to compare, has a judge model score every answer against criteria you wrote, and reports a score, a latency and a price per model. It never guesses — every number comes from a real call.

DodoRouter exposes this as an **MCP server** at `{base_url}/mcp`, authenticated with **OAuth 2.1**. There is no second API key to create, and no secret ever lands in a config file.

## Connect an agent

One command:

```bash
claude mcp add --transport http dodorouter https://api.dodorouter.com/mcp
```

Then use it once (`/mcp` in Claude Code, or just ask it to list your routers). Claude Code opens your browser, you sign in with your usual magic link if you are not already, and a consent screen asks what this agent may do. Approve, and it is connected.

What happened under the hood, in case you are debugging it:

1. The agent discovered the server from `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-authorization-server`.
2. It **registered itself** ([RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)) — nobody can pre-register a desktop agent, because its loopback callback port is not known until it starts.
3. It sent you to `/oauth/authorize`, which rendered the consent screen against the DodoRouter session you already had.
4. Your approval minted a short-lived access token, audience-bound to this MCP endpoint.

Registering grants nothing on its own. A client gets no token until a signed-in user approves it, and the token it gets carries only the permissions ticked on that screen.

Any MCP client that speaks OAuth works — the endpoint is not Claude Code specific. Point it at the same URL.

## What you are approving

The consent screen lists four permissions. They are ticked by default because the agent asked for them, but you can untick any of them before approving.

| Permission | Grants | Sensitive |
|---|---|---|
| `logs:read` | Models, token counts, cost, latency and status for your requests. **No prompt or response text.** | |
| `logs:read_bodies` | The stored request and response text itself — everything your product sent and received. | ⚠️ |
| `evals:read` | Evaluation setups, scores, rankings and judge feedback. | |
| `evals:write` | Create evaluations and start benchmarks. **Running a benchmark calls providers and spends money.** | ⚠️ |

`logs:read_bodies` is the one to think about. Everything else is metadata; that one is your product's actual traffic, including whatever your users typed. An agent can rank models on price and quality with only `logs:read` — it just cannot read the transcripts to write good criteria.

There is no hierarchy: granting `logs:read_bodies` does not imply `logs:read`. Each is granted explicitly.

Refusing a permission is not the same as an error. The agent still connects; the tools it cannot use say so, naming the permission that would have worked, so it can tell you what to grant.

## The tools

| Tool | What it does | Needs |
|---|---|---|
| `get_guide` | The full evaluation workflow, in prose. **An agent should read this first.** | — |
| `list_routers` | Every router this connection reaches | — |
| `list_logs` | Recent requests, with `evaluable` per row | `logs:read` |
| `get_log` | One request, with its stored bodies | `logs:read` (+ `logs:read_bodies` for text) |
| `list_eval_targets` | Your provider keys × the models each can serve, with list prices | `evals:read` |
| `list_evals` | Evaluations created against this router's logs | `evals:read` |
| `get_eval` | Status, per-model rankings, judge feedback, individual runs | `evals:read` |
| `create_eval` | Create an evaluation (optionally start it immediately) | `evals:write` |
| `run_eval` | Run or re-run the whole benchmark | `evals:write` |
| `retry_eval` | Re-run only the runs that failed | `evals:write` |
| `cancel_eval` | Stop a running benchmark; stored answers stay | `evals:write` |

`create_eval` accepts either one `request_log_id` or a `request_log_ids` set — with a set, every candidate answers every log and the ranking aggregates across them, so the score answers "on my traffic" rather than "on this one request". It also takes `prompt_variants` to hold the model constant and vary the system prompt: each variant patches the served request, and the ranking carries one row per model × variant under the same judge.
| `send_feedback` | Send feedback about the agent surface to the DodoRouter team | — |

Most tools take an optional `router` slug. It is optional when your connection reaches exactly one router and required when it reaches several — rather than silently picking one.

`get_guide` exists because tool descriptions can say what an argument is but not what makes a result trustworthy. The guide covers the parts that decide whether the numbers mean anything: include the model you use today as a candidate or you have no baseline, read `rubric_feedback` before trusting a score, and `cost_usd` is `$0` on subscription keys so `list_cost_usd` is the comparable figure.

## Seeing what an agent did

**Dashboard → Agent Activity.**

Every call is recorded — including the refused ones. A 401 from a token that never verified is a row, and so is a tool call rejected for a missing permission; a log that only recorded successes could not tell "nothing went wrong" from "we have no way to tell".

The page shows:

- **Connected agents**, with how many calls each made and when it was last seen
- **Which of them actually read prompt or response text**, not merely which were granted permission to
- **Every call**, filterable by allowed / denied / errored, with the tool name and which record it touched

## This is not your router's API key

A router's API key sends traffic. It cannot read traffic back, and that is deliberate: if one credential did both, a leaked `.env` would stop being "someone is burning my tokens" and become "someone has every prompt my product ever sent".

So:

- Your router key on `/mcp` → **401**. Use the OAuth flow.
- An agent connection on `/r/{router}/v1/chat/completions` → **401**. Use the router key.

An agent connected here cannot send requests through your router. If you want it to test a prompt change, change the prompt in your product, let it make one real call, and evaluate that new log.

## Self-hosting

The OAuth server needs **HTTPS**. Both the issuer and the audience must be `https://` URLs — there is no localhost exemption.

`ATTESTO_ISSUER` and `ATTESTO_AUDIENCE` are read at **boot**, not baked into the release — set them wherever you set the app's other runtime environment variables (e.g. `~/dodorouter/.env` on the server) and restart:

```bash
ATTESTO_ISSUER=https://router.example.com
ATTESTO_AUDIENCE=https://router.example.com/mcp
```

If unset, the issuer defaults to `https://` plus the endpoint's own public host (`PHX_HOST`), and the audience defaults to `<issuer>/mcp` — so a correctly configured `PHX_HOST` alone is often enough, and no release needs to be rebuilt just to change these.

For local development, `mix attesto_phoenix.gen.dev_https` (with [mkcert](https://github.com/FiloSottile/mkcert) installed) generates a locally-trusted certificate and the app serves TLS on port 4443 alongside the plain HTTP dashboard on 4000.

## Troubleshooting

**The agent connects but every tool says "UNAVAILABLE".** It is missing permissions. Reconnect and tick the ones it needs on the consent screen — the tool description names them.

**`POST /mcp` returns 401 with a `WWW-Authenticate` challenge.** That is the flow working: the challenge points the client at the discovery document so it can start the OAuth exchange. If the client stops there, check that `ATTESTO_ISSUER` matches the URL actually being served.

**The consent screen never appears.** The agent must be able to reach `/oauth/authorize` in a browser on the same host you are signed in to. A mismatch between the issuer and the address you visit means you are signed in to one origin and consenting on another.

**Nothing to evaluate.** `list_logs` only shows requests your router actually served, and only some are replayable — `evaluable` and `not_evaluable_because` say which and why. A request whose stored body was truncated cannot be replayed.
