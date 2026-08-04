# Goal

DodoRouter is supposed to help people build, debug and deploy harnesses. It makes it easy to observe what's being sent to LLM, how much it costs, add evals so you get consistent results over time, etc.

# The bet

Yegge's *The Shape of Things to Come* argues that agentic harnesses will be **bespoke** — "chemically bonded" to the application, and that reusable harness frameworks will fail. Taken seriously, that is an argument against building a harness framework, and *for* what we already are.

If every harness is bespoke, the only durable reusable layer is the seam every harness shares regardless of its shape: **the inference boundary**. Every crew agent, fleet worker and role agent makes the same kind of call to the same handful of providers. That call is where cost is incurred, where quality is decided, and where behaviour becomes observable.

**DodoRouter's bet: own the inference boundary, and you can offer bespoke harnesses the four things they cannot economically build for themselves.** Those are the four pillars below.

The corollary is a discipline: we do not build the harness. We do not build the orchestrator, the work graph, or the VM dashboard. Beads owns the work graph. The operator owns the harness. We own the seam.

# What the essay says the world looks like

Load-bearing claims, in rough order of how much they should move our roadmap:

1. **Token economics dominate.** ~$87k/month of list-price token burn, ~69B tokens in a month, sustained at ~$2.8k actual by rotating twelve $200 Max accounts — roughly 30x off list. Held up by **96% cache hits**. Agents draw from a "token tap"; some production pools are deliberately unreachable by the fleet so prod can't be starved by dev.
2. **Fleets, not users.** Work splits into crew (design/production), fleet (implementation), and standing role agents (SRE, deploy watch, abuse, QA, intake). Different tiers deliberately run different models — Fable for design, Opus for implementation, Sonnet for most standing roles, a cheaper fallback fleet when Max tokens deplete.
3. **Human code review dies; agentic review replaces it.** Design → implement → review, all by agents. The quality gate stops being a person and becomes a mechanism.
4. **CI/CD collapses at agentic throughput.** 175+ commits/day against 30-minute builds broke merge queues; the answer was to abandon bisection and swarm-diagnose instead.
5. **The Castellan.** One console: per-account token burn, per-machine service state, P0 banners, and an "attention panel" of the highest-priority decisions waiting on a human.

(3) and (4) are about the harness and the repo — not ours to build. (1), (2) and (5) land squarely on the inference boundary.

# Where we already stand

More of the substrate exists than we've been giving ourselves credit for:

- `request_logs` carries **`estimated_cost_usd` alongside `list_cost_usd`** — actual spend vs. pay-as-you-go price for the same tokens. That *is* Yegge's 30x arbitrage, already measured per request. We are the only party positioned to compute it, because we're the only party that knows both which key served the call and what the tokens would have cost on demand.
- `cache_read_tokens` / `cache_write_tokens` per request, plus a hard-won understanding of how format conversion breaks Anthropic cache prefixes (see AGENTS.md, "Prompt Cache Fidelity Through Format Conversion" — a breakpoint bug there cost ~330k extra cache-write tokens per session).
- `SessionTree` collapses a session's shared prefixes into a branching tree — the structure you need to *see* a cache prefix, not just count tokens.
- `Recordings` (capture windows), `Replays` (re-run a log, linked to source), `Evaluations` (LLM judge, rubric, multi-candidate targets, repetitions, benchmark batches).
- `Providers.KeyHealth` — a real state machine for key validity vs. quota vs. provider outage.
- Fallback chains, per-step model/provider/reasoning-effort, OpenAI + Anthropic + Responses-API compatibility.

The gap is not primitives. It's that the primitives aren't wired into the workflows a fleet operator actually has.

# The four pillars

## 1. The Token Tap — pooled, quota-aware, reservable capacity

**The need.** Rotating a dozen subscription accounts, drawing until one depletes, moving on, and keeping production pools isolated from the dev fleet.

**Where we are.** A `routing_step` binds to exactly one `provider_key_id`, and fallback advances to the *next step*. Reproducing twelve-account rotation today means twelve near-duplicate steps, with no quota awareness and no reservation. Depletion is only discoverable after a failed call.

**What's missing.** A key *pool* as a first-class object: N keys under one logical slot, selection policy across them (round-robin / least-burned / drain-in-order), per-key burn and quota-window accounting, exhaustion prediction rather than exhaustion discovery, and reservation so a pool tagged `prod` is unreachable from a dev router.

**Why it's ours.** We already see every token through every key. Nobody else can attribute burn to a key without being the proxy.

## 2. Cache Fidelity — make the invisible cost bug visible

**The need.** 96% cache hits is the entire economic argument. A broken prefix doesn't error, doesn't slow down, and doesn't show up anywhere — it just quietly multiplies the bill.

**Where we are.** We log read/write cache tokens per request and can reconstruct conversation prefixes via `SessionTree`. We have already diagnosed this class of bug by hand, twice.

**What's missing.** The detection made automatic and productised: the signature is `cache_read` pinning at a fixed value while `cache_creation` grows monotonically across a session. Surface it as an alert with the diverging turn identified, and the diff of what changed in the prefix.

**Why it's ours.** Requires holding the full session prefix history *and* the token accounting together. That is exactly and only the proxy's position.

## 3. Fleet Observability — agent identity as a first-class dimension

**The need.** The Castellan's per-account burn and attention panel. An operator with 18 crew agents, an Opus fleet and a dozen standing roles needs to ask "what is Gargoyle costing me" and "which agent regressed", not "show me requests".

**Where we are.** We have `session_id` / `session_name` and per-request everything. There is no notion of *who* made the call — agent, role, or tier.

**What's missing.** An agent/role dimension carried through logs (header-driven, like the existing session header), rollups by agent and by tier, and an attention surface that pushes anomalies (cost spike, error-rate change, eval-score drop, cache regression) instead of waiting to be browsed. This is where pillars 1, 2 and 4 surface to a human.

## 4. The Downgrade Loop — evidence-backed model selection

**The need.** The essay assigns Fable to design, Opus to implementation, Sonnet to standing roles, a cheap fleet to fallback. Every one of those is a guess about "what's the cheapest model that still does this job." It's the highest-value routing decision an operator makes, and today it's made on vibes.

**Where we are.** Record → replay → judge all exist as separate features. They have never been joined into one workflow.

**What's missing.** The loop, as one motion: record a role's real production traffic → replay it against a cheaper candidate → score both with the judge → report the score delta against the cost delta → apply as a routing change if it holds. Then keep the eval running against live traffic so the decision stays honest.

**Why it's ours.** This is the eval-as-quality-gate thesis (claim 3) applied where we actually have standing. We can't review their code — but we can be the mechanism that says "Sonnet is as good as Opus for this role, at a fifth the price," with evidence.

# What we deliberately don't build

Stated so it stays stated:

- **Not the work graph.** Beads owns it. We integrate with it at most.
- **Not the orchestrator or the harness.** The essay's core claim is that these must be bespoke. Building one puts us in the category the essay predicts will fail.
- **Not machine/VM/service monitoring.** The Castellan aggregates it; we feed it the inference slice, we don't reimplement it.
- **Not an agent runtime.** We are the boundary, not the runner.

# Before the pillars: the parked fidelity stack

Four-plus commits of proxy-fidelity work sit unlanded as separate jj heads, none in `@`'s ancestry (epic `dodo_router-dor`). This is mostly written and tested already, and one item is not a roadmap item at all — it's an active bug:

**`Adapters.Anthropic.call/4` ignores client headers.** The parameter is `_client_headers`; headers are built from `auth_headers(api_key)` alone, emitting only `anthropic-beta: oauth-2025-04-20`. Every beta the client opted into is dropped — including `extended-cache-ttl`, which silently demotes proxied Claude Code sessions from a 1h cache TTL to 5 minutes. For agent sessions with long tool gaps, that is the difference between a cache hit and re-writing the whole prefix, every turn.

That inverts the framing of pillar 2. **We are not only failing to detect cache degradation — we are causing some of it.** Fixing the cause has to precede shipping the detector, or the detector's first finding will be us. The fix already exists in jj `lrrlqnlm` (branch `push-lrrlqnlmqwvx`, pushed to origin, never merged).

A caution learned here: a memory note recorded that branch as "shipped on main." It was not. Pushed ≠ merged; verify against the tree.

# Sequencing

Rough order, on dependency and leverage rather than calendar:

0. **Land the parked stack**, header forwarding first. It blocks the cache detector below.
1. **Cache Fidelity (pillar 2)** next. Smallest lift on top of existing data, and it demonstrates the thesis outright — value nobody who isn't the proxy can deliver.
2. **Token Tap (pillar 1)** next. The largest schema change (pools, per-key burn, reservation), and pillar 3's most interesting rollup depends on per-key burn existing.
3. **Fleet Observability (pillar 3)**. The agent dimension is cheap to add early (a header), so land the ingest side alongside pillar 1 even if the surfaces come later. The attention panel wants pillars 1, 2 and 4 to have something to say.
4. **Downgrade Loop (pillar 4)** last of the four — it's assembly of existing parts, and it's more persuasive once burn data exists to quantify the savings.

Open question worth resolving before pillar 1: whether pools are modelled as a new object routing steps point at, or as relaxing `routing_step.provider_key_id` into a set. That decision sets the migration cost, and hot-upgrade rules (AGENTS.md) mean it's expensive to get wrong.
