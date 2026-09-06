# DodoRouter evaluations — agent guide

You are working on a product whose LLM calls go through DodoRouter. These tools
let you answer, with evidence rather than a guess:

- what a given call actually costs today
- whether a cheaper or faster model answers it well enough to switch
- whether a prompt change made the answers better or only different

It works by replay: you point at a request the product **really made**, list the
models to try, write the criteria a good answer has to meet, and a judge model
scores every answer. You get a score, a latency and a price per model.

Money is a JSON number in USD. Times are ISO 8601 UTC. Most tools take a
`router` slug — optional when your token reaches exactly one router, required
otherwise; `list_routers` shows them.

Your access carries scopes. A tool you lack the scope for says so in its own
description, and calling it names the scope that would have worked. Ask the
person who approved the connection to grant it and reconnect.

## The loop

### 1. Find a request to evaluate

    list_logs { "limit": 20, "status": "success" }

Each row carries `cost_usd`, `total_tokens`, `latency_ms`, `model` and — the one
to check first — `evaluable`. A log whose stored request body was truncated or
is not a chat request cannot be replayed; `not_evaluable_because` says which.
Pick an evaluable one.

Nothing to evaluate yet? Make the product issue one real call through the
router, then list again. You cannot send that call yourself with these tools —
the proxy endpoints take the router's **proxy API key**, a different credential
precisely so that reading traffic and sending it are granted separately.

A served log stays the anchor of every evaluation — real traffic, with the
real tools and history attached. To test a prompt that was never served,
patch the anchor with `prompt_variants` (below) rather than inventing a
request from scratch: everything except the hypothesis under test stays
exactly what production sent.

**The strongest source is a recording.** An operator can start a capture
window on the router (`list_recordings` shows them); every request the
product made while it ran is in it, and nobody hand-picked any of them.
Pass a recording's id to `create_eval` as `recording_id` and every
replayable captured request becomes a source log — evenly sampled across
the capture in time order when more than 20 are replayable, so the sample
is not biased toward how a session starts. When a recording exists that
covers the traffic you care about, prefer it over picking logs by hand.

    get_log { "id": "<id from list_logs>" }

returns the full stored request and response bodies, if you hold
`logs:read_bodies`. Without it the fields come back as `{"withheld": "..."}`
rather than missing, so you can tell "empty" from "not yours to read".
Read them before writing criteria: the criteria have to be about *this* task.

### 2. See what you can try

    list_eval_targets {}

One entry per provider key configured on the account, each with the models it
can serve and their list prices per million tokens. `provider_key_id` + `model`
is what identifies a candidate; you never send a provider name, it is derived
from the key.

The unfiltered list is every key × every model. When you already know what you
are looking for, pass `provider` (exact slug), `model` (case-insensitive
substring) or `limit` — a capped result carries `truncated: true` so you can
tell a short list from a complete one.

Prices here are the catalog's list prices. The `avg_cost_usd` you get back after
a run is measured from the actual call, which is the number to trust.

### 3. Create the evaluation

    create_eval {
      "request_log_id": "<id from step 1>",
      "name": "Support reply quality",
      "criteria": "Answers the customer's actual question. States the refund window correctly (30 days). No invented policy. Under 120 words. Warm but not chatty.",
      "good_examples": "optional — paste an answer you would ship",
      "bad_examples": "optional — paste one you would not",
      "judge": { "provider_key_id": "<key>", "model": "<strong model>" },
      "candidates": [
        { "provider_key_id": "<key>", "model": "<the model you use today>" },
        { "provider_key_id": "<key>", "model": "<a cheaper one>" }
      ],
      "repetitions": 3,
      "run": true
    }

Notes that change the result:

- **The incumbent is included for you.** A score is only meaningful next to
  another score from the same rubric and the same judge, so the model that
  served the source log is added as a candidate automatically when you leave
  it out (pass `include_incumbent: false` to opt out). If the serving key is
  no longer on the account, nothing is added — check the candidate list in
  the result if the baseline matters.
- **Write criteria that can fail.** "Be helpful" scores everything in the
  eighties and tells you nothing. Name the facts that must be right, the format,
  the length, and what must not appear.
- **Scores are 0-100, everywhere.** The judge is instructed to answer on that
  scale and every stored score (`avg_score`, `criterion_scores`, per-run
  `score`) lives on it. Write criteria in those terms — a rubric that implies
  another scale ("rate 1-5") makes the judge answer off-scale, which now fails
  the run's judge stage rather than being silently rescaled; `retry_eval`
  re-judges cheaply after you fix the rubric.
- **`repetitions` is your variance estimate**, not a quality boost. 3 is a
  reasonable default; the result reports `score_stddev` per model, and a gap
  between two models smaller than their spread is not a result.
- **The judge is a model and it costs money.** Use a strong one — its job is
  harder than the candidates'. It is never told which model produced which
  answer.
- **Keep the judge off the candidates' provider key.** Judging and generating
  through one account spends the same quota twice, and a rate-limited judge
  scores nothing while every answer is still paid for. When they do share a
  key, the result says so (`shared_judge_key_label` and a `warnings` entry).
- `run: true` starts the benchmark immediately. Omit it to create the evaluation
  and start it later with `run_eval`.

### 4. Read the result

    get_eval { "id": "<id>" }

Poll until `running` is false. The default payload is built for exactly that
polling: status, `summary`, `rankings`, `rubric_feedback` and `retryable` —
not the full run detail. When you want more, ask:

    get_eval { "id": "<id>", "include": ["runs", "criteria"] }

`runs` carries up to 2,000 characters of `output_preview` per run — a full
batch can be large, so request it once at the end rather than on every poll.
`include: ["attempts"]` adds each run's `previous_attempts` — the attempts a
retry replaced — which answers "did this model fail the first time too"
(it implies `runs`). `blockers` is likewise omitted while the benchmark is
running (the keys were checked at start). Then:

- `rankings` — one row per model: `avg_score`, `score_stddev`, `avg_latency_ms`,
  `avg_cost_usd`. This is the quality-versus-price table. On a multi-log
  benchmark each row also carries `per_source` — the same aggregates per
  source log, sorted worst-first. Read it before switching: the aggregate
  average hides a candidate that is fine on 18 of 20 requests and
  catastrophic on 2, and a weak row's `source_log_id` fed to `get_log`
  shows you exactly which request breaks it.
- `summary` — totals for the batch, including what the whole benchmark cost.
- `savings_projection` — on a recording-based benchmark only: each
  candidate's generation cost scaled to the capture's real request rate,
  next to what the traffic cost as served (`baseline_monthly_cost_usd`).
  This is the "$X/month at your current rate" figure a switch decision
  needs. At API list prices, judge spend excluded; absent when the capture
  window is under 10 minutes, because a rate measured that briefly is an
  artifact of when the operator clicked stop, not a property of the
  traffic.
- `applied_changes` — present once someone acted on the verdict: the
  routing changes made from this benchmark, each with what served before,
  what serves now, and whether it was reverted. Applying is the operator's
  click in the dashboard ("Route here" on a ranking row) — these tools
  read the audit trail, they do not change routing. If your benchmark
  earned a switch, say so to your operator and point at the evaluation.
- `monitor` — present once the operator turned on live monitoring for an
  applied verdict: the same rubric and judge keep scoring a few live
  answers per interval, and `alerted_at` is set while the rolling live
  average sits below the benchmark baseline (it clears on recovery). A set
  `alerted_at` means the downgrade is no longer earning its evidence —
  surface that.
- `rubric_feedback` — **read this before you trust the scores.** It reports how
  often the judge said your criteria were too thin to decide, and what it said
  was missing. If `flagged` is high, fix `criteria` and create a new evaluation;
  the scores you have are noise dressed as numbers.
- `runs` (with `include: ["runs"]`) — every individual run: score,
  `criterion_scores`, `issues` the judge raised, `output_preview`, and
  `candidate_log_id` / `judge_log_id`. Pass those ids to `get_log` for the
  full text of an answer or of the judge's reasoning. `served_model` is what
  the provider's response claimed actually answered; when
  `served_model_mismatch` is true the provider resolved your requested name
  to something else (an alias or snapshot), and the ranking row for
  `model` is really measuring that.

A `status` of `failed` on a run is not a low score — it is a call that never
produced a comparable answer. `error` says why in prose; `error_category` says
the same thing as a stable token you can branch on (`rate_limited`,
`auth_error`, `provider_key_missing`, `empty_response`, `judge_unparseable`,
`judge_setup`, `crashed`, `cancelled`, `interrupted`, …— `null` on runs
recorded before the field existed). `failure_stage` says where it broke
and `retryable` whether trying again could help. `retry_eval` re-runs only the
failed runs. Failed runs are excluded from `avg_score` but their cost is still
in `summary.total_cost_usd`.

The moment a benchmark is clearly doomed — wrong rubric, wrong candidates —
`cancel_eval` stops it: in-flight provider calls are killed and the spending
stops there. Answers already generated stay stored, so a later `retry_eval`
can re-judge them without paying for generation again.

### 5. Change something, evaluate again

Evaluations are immutable on purpose: a score belongs to the rubric, judge and
targets that produced it, so a changed setup is a new evaluation, never an edit.

To A/B a prompt, don't seed new traffic — pass `prompt_variants`:

    "prompt_variants": [
      { "name": "as-served", "system_prompt": null },
      { "name": "v2-terse", "system_prompt": "You are terse. ..." }
    ]

Each variant patches the served request's system prompt (everything else stays
exactly what production sent), every candidate answers every variant, and the
ranking carries one row per model × variant — same judge, same rubric, one
comparison. The judge scores each answer against the request that run actually
sent and never learns variant names. Runs multiply accordingly: check
`planned_runs` before starting.

A variant can also carry `message_patches` — `{index, content}` replacements
for individual messages of the served request. This is how you test a context
transform rather than a prompt: compress a tool-result message offline, send
the compressed text as the patch, hold the model constant, and the benchmark
answers whether reasoning survived the compression. Indexes are 0-based into
the request as served; a patch that points at no message is refused at
creation with the log named. You compute the transform — the router never
executes your code, it only replays the request you describe.

You never have to re-send the rubric to vary one thing: pass `from_eval_id`
to `create_eval` and everything — criteria, examples, judge, candidates,
repetitions, the source log — carries over from that evaluation, with any
argument you pass alongside overriding its copy. Swap `request_log_id` to
point the same rubric at a new log, or `candidates` to try another model.

### Per-decision replay for agent trajectories

For recorded agent traffic there is a sharper question than "is the answer
good": *at each decision point, would the candidate have made a better next
move than production did?* Pass `comparison_mode: "next_action"`. Each
source log's request already carries the full frozen history — every real
tool result, because it really happened — so the candidate proposes ONE
next action, nothing after that turn is simulated, and the judge compares
it against the recorded action: better, equivalent, or worse. Rankings then
carry a `decisions` rollup per candidate ("better-or-equal move in N% of
decisions") alongside the usual scores. Combine it with `recording_id` and
the decision points are a whole captured session. Requires every source
log's stored response to be extractable — a log without a recorded action
is refused by name at creation.

## Runner limits

Three limits shape every benchmark; know them before reading close results:

- **10 minutes per candidate or judge call.** Evaluation replays wait for
  the answer they are paying to measure — a build-shaped generation that
  legitimately runs five minutes is rankable. (Live proxy traffic keeps a
  120s deadline; there, failing over beats waiting out a stuck provider.)
  A run that still hits 10 minutes is failed by our deadline, not by the
  model — treat latencies approaching it as unrankable. Long candidates ×
  3-way concurrency make batches slow: check `planned_runs` and scope the
  first pass tight.
- **Rate limits back off twice** (2s, then 8s), honoring the provider's
  `Retry-After` when it sends one (capped at 30s). A run that still comes
  back rate-limited after that fails with `error_category: "rate_limited"` —
  `retry_eval` later is the recovery, and a judge on its own key (see above)
  is the prevention.
- **Three runs execute concurrently per benchmark**, regardless of how many
  provider keys are involved. Candidates sharing one key contend with each
  other and with the judge.

## Reading the numbers honestly

- **Compare within one evaluation, not across two.** Different judges, different
  rubrics and different source requests are different scales.
- **One source log is one task.** A model that wins on one support reply has
  not been shown to win on your traffic. Pass `recording_id` (best — a
  capture of real traffic nobody hand-picked) or `request_log_ids` with
  several logs that cover the shapes your product actually sees — one
  benchmark, one judge, one ranking aggregated across all of them — before
  you switch anything. Every candidate answers every log, so runs =
  logs × candidates × repetitions; `planned_runs` in the result states the
  volume before you start it.
- **`cost_usd` can be $0** on a plan/subscription key, because nothing was
  metered. `list_cost_usd` is what the same tokens would have cost at API list
  price, and is the comparable number when mixing key types.
- **A `null` cost means unknown, not free.** When a request's token counts were
  never reported (both cost fields and the token counts are `null`), there is
  nothing to price — exclude the row from cost comparisons rather than
  treating it as $0.
- **Latency here includes the proxy's own hop** and one cold call per run; it
  ranks models against each other rather than predicting production latency.

## Reading your traffic

The same scope that lets you pick a source request lets you answer spend
and quality questions without a benchmark:

- `get_session { "session_id": "..." }` — aggregates for one session
  (tag each of your product's questions with an `X-Session-Id` header and
  this answers "this question cost $1.40"). Costs come as two figures:
  `cost_usd` is what was actually metered, `list_cost_usd` the same tokens
  at pay-as-you-go API prices. It answers consistently while the session
  is still in flight — an id with no requests yet returns zeros, never an
  error — so poll it freely.
- `list_sessions` — recent sessions with the same per-session figures.
- Both `get_log` and `get_session` carry `token_attribution`: input tokens
  bucketed by what the context was made of (system prompt, tool
  definitions, history, tool results — split `by_tool` — and pasted file
  contents) and how much of each sat in the cacheable prefix. "Tool
  results are 60% of this question's tokens, mostly one Read, and they sit
  after the cache breakpoint" is the most actionable sentence in context
  engineering. The tokens are allocated pro-rata against the billed total
  (no provider tokenizer is public), so trust the shares; treat per-bucket
  absolutes as estimates.
- `get_spend { "hours": 24 }` — spend grouped by served model.
- `get_log.cache_diagnosis` explains structural cache evidence without
  `logs:read_bodies`. Start with `list_logs` filtered by `session_id`, then
  inspect the affected requests. `observation` separates zero reported reads,
  positive cache reads, and unreported usage. `first_change` names a component
  and one-based item index; appending messages is normal prefix growth.
  `prefix_changed` is observed, not proof of provider causality. Expiry is
  only likely (uniform explicit requested TTL); overlapping requests support
  only a possible race. `provider_no_hit` means unchanged shared prefix with
  zero reads, not a provider defect; eligibility, shard and actual expiry
  remain unknown. Comparison is to the latest earlier-starting already-recorded
  successful request in the same router/session, available at write
  time; `previous_log_id` identifies it. Model/provider/key/endpoint changes
  make comparison incompatible. Old rows return null. Fingerprints survive
  body removal but are not exposed by MCP; they cannot locate exact tokens.
  `current`/`previous` carry provider-key identity, hashed endpoint/cache key,
  serving model, requested retention, attempt start/end times (Unix ms), and
  other in-flight requests on this router/node. `changes` names differing
  routing/settings/header fields; `matched_messages` out of
  `previous_message_count` describes the shared prefix. Tracked headers are
  anthropic-beta/version, openai-beta, chatgpt-account-id, session_id,
  conversation_id, and x-session-id; no raw header values are exposed.
  A router's concurrent-request count alone does not establish a cache race.
- `get_cache_stats { "hours": 24 }` — prompt-cache hit rate and token
  volumes. A falling hit rate on an agent workload usually means something
  volatile slipped into the cached prefix.
- `get_recording { "id": "..." }` — aggregates for one capture window.

**Every aggregate is drillable through `list_logs`**: pass a spend row's
`model`, a session's `session_id`, or a recording's `recording_id` back as
a filter (plus `since`/`until` for the same window) to see the requests
behind any number. `total` on the result counts every match, so a capped
page is never mistaken for the whole answer. None of these return request
or response text — bodies stay behind `get_log` and its own scope.

## Tool reference

| Tool | Purpose | Scope |
|---|---|---|
| `get_guide` | This guide | — |
| `list_routers` | Every router this token reaches | — |
| `list_logs` | Recent requests, with `evaluable` per row; the drill-down for every aggregate | `logs:read` |
| `list_sessions` | Sessions with per-session cost/tokens/latency | `logs:read` |
| `get_session` | One session's aggregates ("this question cost $1.40") | `logs:read` |
| `get_spend` | Spend by served model over a window | `logs:read` |
| `get_cache_stats` | Prompt-cache hit rate over a window | `logs:read` |
| `get_recording` | One capture window's aggregates | `logs:read` |
| `list_recordings` | Capture windows; benchmark one via `create_eval` `recording_id` | `logs:read` |
| `get_log` | One request, with its stored bodies | `logs:read` (bodies need `logs:read_bodies`) |
| `list_eval_targets` | Provider keys, models, list prices | `evals:read` |
| `list_evals` | Evaluations against this router's logs | `evals:read` |
| `get_eval` | Status, rankings, rubric feedback, runs | `evals:read` |
| `create_eval` | Create one (`run: true` to start it) | `evals:write` |
| `run_eval` | Run or re-run the whole benchmark | `evals:write` |
| `retry_eval` | Re-run only the failed runs | `evals:write` |
| `cancel_eval` | Stop a running benchmark; stored answers stay | `evals:write` |
| `send_feedback` | Tell the team what worked and what did not | — |

Found a rough edge — a missing field, a payload that blew your context, a
warning that would have saved a run? `send_feedback` goes straight to the
people who build this surface; it has been reshaped by exactly that kind of
feedback before.
