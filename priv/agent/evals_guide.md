# DodoRouter evaluations — agent guide

You are working on a product whose LLM calls go through DodoRouter. This API
lets you answer, with evidence rather than a guess:

- what a given call actually costs today
- whether a cheaper or faster model answers it well enough to switch
- whether a prompt change made the answers better or only different

It works by replay: you point at a request the product **really made**, list
the models to try, write the criteria a good answer has to meet, and a judge
model scores every answer. You get a score, a latency and a price per model.

    Base URL: {{BASE}}
    Router:   {{SLUG}}
    Auth:     Authorization: Bearer $DODO_AGENT_TOKEN

The token is an **agent token**, minted at /agent-tokens — not the router's
proxy API key, which cannot read this surface. It carries scopes; a 403 names
the one you are missing.

Holding a token but no router slug? `GET {{BASE_ROOT}}/agent` lists every
router this token reaches, each with its own guide.

Everything is JSON. Money is a JSON number in USD. Times are ISO 8601 UTC.
Every error names this guide in its `see` field.

## The loop

### 1. Find a request to evaluate

    GET {{BASE}}/logs?limit=20&status=success

Each row carries `cost_usd`, `total_tokens`, `latency_ms`, `model` and — the
one to check first — `evaluable`. A log whose stored request body was
truncated or is not a chat request cannot be replayed; `not_evaluable_because`
says which. Pick an evaluable one.

Nothing to evaluate yet? Make the product issue one real call through the
router, then list again. You cannot send that call yourself with this token —
`{{BASE}}/v1/chat/completions` takes the router's **proxy API key**, which is a
different credential precisely so that reading traffic and sending it are
granted separately.

There is no way to evaluate a prompt that was never served — the point of the
source log is that it is real traffic, with the real system prompt, tools and
history attached.

`GET {{BASE}}/logs/:id` returns the full stored request and response bodies,
if your token holds `logs:read_bodies`. Without it the fields come back as
`{"withheld": "..."}` rather than missing, so you can tell "empty" from
"not yours to read".
Read them before writing criteria: the criteria have to be about *this* task.

### 2. See what you can try

    GET {{BASE}}/evals/targets

One entry per provider key you have configured, each with the models it can
serve and their list prices per million tokens. `provider_key_id` + `model` is
what identifies a candidate; you never send a provider name, it is derived
from the key.

Prices here are the catalog's list prices. The `avg_cost_usd` you get back
after a run is measured from the actual call, which is the number to trust.

### 3. Create the evaluation

    POST {{BASE}}/evals
    {
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

- **Include the model you use today as a candidate.** A score is only
  meaningful next to another score from the same rubric and the same judge.
  Without the incumbent in the list you have numbers but no baseline.
- **Write criteria that can fail.** "Be helpful" scores everything in the
  eighties and tells you nothing. Name the facts that must be right, the
  format, the length, and what must not appear.
- **`repetitions` is your variance estimate**, not a quality boost. 3 is a
  reasonable default; the response reports `score_stddev` per model, and a
  gap between two models smaller than their spread is not a result.
- **The judge is a model and it costs money.** Use a strong one — its job is
  harder than the candidates'. It is never told which model produced which
  answer.
- `run: true` starts the benchmark immediately. Omit it to create the
  evaluation and start it later with `POST /evals/:id/run`.

### 4. Read the result

    GET {{BASE}}/evals/:id

Poll until `running` is false. Then:

- `rankings` — one row per model: `avg_score`, `score_stddev`,
  `avg_latency_ms`, `avg_cost_usd`. This is the quality-versus-price table.
- `summary` — totals for the batch, including what the whole benchmark cost.
- `rubric_feedback` — **read this before you trust the scores.** It reports
  how often the judge said your criteria were too thin to decide, and what it
  said was missing. If `flagged` is high, fix `criteria` and create a new
  evaluation; the scores you have are noise dressed as numbers.
- `runs` — every individual run: score, `criterion_scores`, `issues` the judge
  raised, `output_preview`, and `candidate_log_id` / `judge_log_id`. Fetch
  those ids from `GET {{BASE}}/logs/:id` for the full text of an answer or of
  the judge's own reasoning.

A `status` of `failed` on a run is not a low score — it is a call that never
produced a comparable answer. `error` says why (provider rejected it, no
content, judge returned unparseable output). Failed runs are excluded from
`avg_score` but their cost is still in `summary.total_cost_usd`.

### 5. Change something, evaluate again

Evaluations are immutable on purpose: a score belongs to the rubric, judge and
targets that produced it, so a changed setup is a new evaluation, never an
edit. To test a prompt change, change the prompt in the product, make one real
call, and evaluate that new log with the same criteria and the same judge.

## Reading the numbers honestly

- **Compare within one evaluation, not across two.** Different judges,
  different rubrics and different source requests are different scales.
- **One source log is one task.** A model that wins on one support reply has
  not been shown to win on your traffic. Repeat over several logs that cover
  the shapes your product actually sees before you switch anything.
- **`cost_usd` can be $0** on a plan/subscription key, because nothing was
  metered. `list_cost_usd` is what the same tokens would have cost at API
  list price, and is the comparable number when mixing key types.
- **Latency here includes the proxy's own hop** and one cold call per run; it
  ranks models against each other rather than predicting production latency.

## Endpoint reference

| Method | Path | Purpose |
|---|---|---|
| GET | `{{BASE_ROOT}}/agent` | **Start here.** Every router this token reaches, and its scopes |
| GET | `/agent` | This guide, and the endpoint list as data |
| GET | `/logs` | Recent requests. `limit`, `offset`, `status`, `provider`, `model`, `call_type`, `favorites_only` |
| GET | `/logs/:id` | One request with bodies. Accepts an id or a `request_id` |
| GET | `/evals/targets` | Provider keys, models, list prices |
| GET | `/evals` | Evaluations against this router's logs. `limit`, `offset` |
| POST | `/evals` | Create one (`run: true` to start it) |
| GET | `/evals/:id` | Status, rankings, rubric feedback, runs |
| POST | `/evals/:id/run` | Run or re-run. 409 while one is already running |

Every path is relative to `{{BASE}}`.
