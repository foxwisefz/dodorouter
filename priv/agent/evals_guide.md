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

There is no way to evaluate a prompt that was never served — the point of the
source log is that it is real traffic, with the real system prompt, tools and
history attached.

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
`blockers` is likewise omitted while the benchmark is running (the keys were
checked at start). Then:

- `rankings` — one row per model: `avg_score`, `score_stddev`, `avg_latency_ms`,
  `avg_cost_usd`. This is the quality-versus-price table.
- `summary` — totals for the batch, including what the whole benchmark cost.
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
To test a prompt change, change the prompt in the product, make one real call,
and evaluate that new log with the same criteria and the same judge.

You never have to re-send the rubric to vary one thing: pass `from_eval_id`
to `create_eval` and everything — criteria, examples, judge, candidates,
repetitions, the source log — carries over from that evaluation, with any
argument you pass alongside overriding its copy. Swap `request_log_id` to
point the same rubric at a new log, or `candidates` to try another model.

## Reading the numbers honestly

- **Compare within one evaluation, not across two.** Different judges, different
  rubrics and different source requests are different scales.
- **One source log is one task.** A model that wins on one support reply has not
  been shown to win on your traffic. Repeat over several logs that cover the
  shapes your product actually sees before you switch anything.
- **`cost_usd` can be $0** on a plan/subscription key, because nothing was
  metered. `list_cost_usd` is what the same tokens would have cost at API list
  price, and is the comparable number when mixing key types.
- **A `null` cost means unknown, not free.** When a request's token counts were
  never reported (both cost fields and the token counts are `null`), there is
  nothing to price — exclude the row from cost comparisons rather than
  treating it as $0.
- **Latency here includes the proxy's own hop** and one cold call per run; it
  ranks models against each other rather than predicting production latency.

## Tool reference

| Tool | Purpose | Scope |
|---|---|---|
| `get_guide` | This guide | — |
| `list_routers` | Every router this token reaches | — |
| `list_logs` | Recent requests, with `evaluable` per row | `logs:read` |
| `get_log` | One request, with its stored bodies | `logs:read` (bodies need `logs:read_bodies`) |
| `list_eval_targets` | Provider keys, models, list prices | `evals:read` |
| `list_evals` | Evaluations against this router's logs | `evals:read` |
| `get_eval` | Status, rankings, rubric feedback, runs | `evals:read` |
| `create_eval` | Create one (`run: true` to start it) | `evals:write` |
| `run_eval` | Run or re-run the whole benchmark | `evals:write` |
| `retry_eval` | Re-run only the failed runs | `evals:write` |
| `cancel_eval` | Stop a running benchmark; stored answers stay | `evals:write` |
