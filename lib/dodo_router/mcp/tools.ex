defmodule DodoRouter.MCP.Tools do
  @moduledoc """
  The tools an agent can call over MCP, and what they do.

  Kept separate from the transport so the interesting half — which scope a tool
  needs, what it returns, how a router argument is resolved — is testable
  without constructing JSON-RPC envelopes.

  These call the contexts directly. The MCP server runs in-process; going out
  over HTTP to our own API would buy nothing and add a hop that can fail on its
  own.
  """

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Principal
  alias DodoRouter.{Evaluations, Logs, Providers, Recordings, Replays}
  alias DodoRouter.Proxy.Adapter.Registry

  @output_preview 2_000

  # Read at compile time from the source tree rather than `priv` at runtime:
  # the guide has to be there for a release too, and a missing file should fail
  # the build, not the first agent that asks for it.
  @guide_path Path.expand("../../../priv/agent/evals_guide.md", __DIR__)
  @external_resource @guide_path
  @guide File.read!(@guide_path)

  @router_arg %{
    "type" => "string",
    "description" =>
      "Router slug. Optional when this token reaches exactly one router; required otherwise. Use list_routers to see them."
  }

  @definitions [
    %{
      name: "get_guide",
      title: "How to evaluate models",
      description:
        "Read this first. The full workflow for comparing models on your own traffic — how to pick a source request, write criteria that can fail, choose a judge, and read the scores without fooling yourself. Tool descriptions say what each call does; this says what makes the numbers mean anything.",
      scopes: [],
      schema: %{"type" => "object", "properties" => %{}}
    },
    %{
      name: "list_routers",
      title: "List routers",
      description: "Every router this token can reach. Most other tools take a router slug.",
      scopes: [],
      schema: %{"type" => "object", "properties" => %{}}
    },
    %{
      name: "list_logs",
      title: "List requests",
      description:
        "Recent requests this router served, with model, tokens, cost and latency. " <>
          "`evaluable` says whether a request can be replayed into an evaluation. " <>
          "`total` counts every match, so a capped page is never mistaken for the whole " <>
          "answer. This is also the drill-down for every aggregate tool: feed a spend " <>
          "row's model, a session's id, or a recording's id back in as filters to see " <>
          "the requests behind any number.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "limit" => %{"type" => "integer", "description" => "Max 100. Defaults to 20."},
          "status" => %{"type" => "string", "description" => "success, fallback or error."},
          "model" => %{"type" => "string", "description" => "Filter by served model."},
          "provider" => %{"type" => "string", "description" => "Filter by serving provider."},
          "session_id" => %{
            "type" => "string",
            "description" => "Only requests tagged with this session id (see list_sessions)."
          },
          "recording_id" => %{
            "type" => "string",
            "description" => "Only requests captured by this recording (see list_recordings)."
          },
          "since" => %{
            "type" => "string",
            "description" => "ISO 8601 lower bound on when the request was served."
          },
          "until" => %{
            "type" => "string",
            "description" => "ISO 8601 upper bound on when the request was served."
          }
        }
      }
    },
    %{
      name: "list_sessions",
      title: "List sessions",
      description:
        "Sessions this router has served, newest activity first — a session groups the " <>
          "requests a client tagged with one X-Session-Id (one agent conversation, one " <>
          "user question). Each row carries request_count, tokens, avg latency, and cost " <>
          "as two figures: cost_usd (actually metered) and list_cost_usd (the same tokens " <>
          "at pay-as-you-go API prices — the comparable number on plan keys).",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "limit" => %{"type" => "integer", "description" => "Max 100. Defaults to 20."},
          "hours" => %{
            "type" => "integer",
            "description" => "Only sessions with activity in the last N hours; omit for all."
          }
        }
      }
    },
    %{
      name: "get_session",
      title: "Get one session's aggregates",
      description:
        "Aggregate stats for one session id: request count, tokens, latency, error split, " <>
          "first/last request, and cost as cost_usd + list_cost_usd separately — the shape " <>
          "for writing \"this question cost $1.40\" back onto your own records. Answers " <>
          "consistently while the session is still in flight: the numbers cover what has " <>
          "been served so far, and an id with no requests yet returns zeros, never an " <>
          "error. token_attribution says what the session's input tokens were made of — " <>
          "\"tool results are 60%, mostly one Read\" is the number that tells you what to " <>
          "fix. Drill down with list_logs {session_id}.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "required" => ["session_id"],
        "properties" => %{
          "router" => @router_arg,
          "session_id" => %{"type" => "string"}
        }
      }
    },
    %{
      name: "list_recordings",
      title: "List recordings",
      description:
        "Capture windows of real traffic on this router — an operator starts one, the " <>
          "product runs, and every request served while it was recording is captured. Pass a " <>
          "recording's id to create_eval as recording_id to benchmark that whole capture in " <>
          "one evaluation: candidates answer real production traffic, not a hand-picked " <>
          "request. request_count counts everything captured; which requests can actually be " <>
          "replayed is decided at create_eval time.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "limit" => %{"type" => "integer", "description" => "Max 100. Defaults to 20."}
        }
      }
    },
    %{
      name: "get_recording",
      title: "Get one recording's aggregates",
      description:
        "Aggregate stats for one capture window: request count, tokens, latency, success " <>
          "split, and cost as total_cost_usd (actually metered) + total_list_cost_usd (the " <>
          "same traffic at API list prices) separately. Drill down with list_logs " <>
          "{recording_id}; benchmark the capture with create_eval {recording_id}.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{
          "router" => @router_arg,
          "id" => %{"type" => "string", "description" => "Recording id from list_recordings."}
        }
      }
    },
    %{
      name: "get_spend",
      title: "Spend by model",
      description:
        "What this router's traffic cost over a window, grouped by served model: requests, " <>
          "tokens, cost_usd (actually metered) and list_cost_usd (the same tokens at " <>
          "pay-as-you-go API prices) per model, highest spend first. Every row is " <>
          "drillable: pass its model and provider to list_logs with the same window to see " <>
          "the requests behind the number.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "hours" => %{
            "type" => "integer",
            "description" => "Window size in hours, 1-720. Defaults to 24."
          }
        }
      }
    },
    %{
      name: "get_cache_stats",
      title: "Prompt-cache stats",
      description:
        "How well prompt caching is working over a window: hit rate, cache-read and " <>
          "cache-write tokens, and how many requests hit the cache at all. A falling hit " <>
          "rate on an agent workload usually means something volatile slipped into the " <>
          "cached prefix; list_logs over the same window finds the requests to inspect.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "hours" => %{
            "type" => "integer",
            "description" => "Window size in hours, 1-720. Defaults to 24."
          }
        }
      }
    },
    %{
      name: "get_log",
      title: "Get one request",
      description:
        "One request in full. Prompt and response text requires the logs:read_bodies scope; " <>
          "without it those fields come back marked as withheld rather than missing. " <>
          "token_attribution buckets the input tokens by what the context was made of " <>
          "(system / tools / history / tool_results with a by_tool split / file_contents) " <>
          "and by cache position — allocated pro-rata against the billed total, so shares " <>
          "are trustworthy; per-bucket absolutes are estimates, not tokenizer output.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{
          "router" => @router_arg,
          "id" => %{"type" => "string", "description" => "Log id, or the request_id."}
        }
      }
    },
    %{
      name: "list_eval_targets",
      title: "List candidate models",
      description:
        "Provider keys and the models each can serve, with list prices per million tokens. A " <>
          "candidate is a provider_key_id plus a model. Models come from the synced catalog, so " <>
          "anything a provider has retired is already absent — a model missing here is not " <>
          "available to name. `billing` says whether a key is metered or a subscription plan. " <>
          "The unfiltered list spans every key × every model; `provider`, `model` and `limit` " <>
          "narrow it, and `truncated: true` marks a capped result.",
      scopes: ["evals:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "provider" => %{
            "type" => "string",
            "description" => "Only keys for this provider slug (exact match, e.g. \"anthropic\")."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Case-insensitive substring matched against model id and display name; " <>
                "keys left with no matching models are omitted."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Maximum number of keys to return, after filtering."
          }
        }
      }
    },
    %{
      name: "list_evals",
      title: "List evaluations",
      description: "Evaluations created against this router's logs.",
      scopes: ["evals:read"],
      schema: %{"type" => "object", "properties" => %{"router" => @router_arg}}
    },
    %{
      name: "create_eval",
      title: "Create an evaluation",
      description: """
      Replay real requests against several models and score the answers with a judge model. The source is one log (request_log_id), a set of logs (request_log_ids), or a whole recording (recording_id) — a recording is the strongest basis, because the sample is production traffic nobody hand-picked.

      The model that served the source log (the incumbent) is added as a candidate automatically when you leave it out — a score only means something next to another score from the same rubric and judge. Pass include_incumbent: false to opt out. Write criteria that can fail: name the facts that must be right, the format, the length, and what must not appear. Set run=true to start it immediately.

      Pick a judge on a metered API key, not a subscription/coding-plan key. Plan credentials are issued for a vendor's own coding environment and may refuse or throttle calls made from anywhere else — as a candidate that costs you one data point, but as the judge it means no scores at all. list_eval_targets reports `billing` per key.

      Avoid putting the judge on the same provider key as a candidate: judging and generating through one account spends the same quota twice, and a rate-limited judge scores nothing. The result carries a warning (`shared_judge_key_label` / `warnings`) when this is the case.
      """,
      scopes: ["evals:write"],
      schema: %{
        "type" => "object",
        # Either a full definition, or a clone: from_eval_id carries every
        # missing field over from the source evaluation.
        "anyOf" => [
          %{"required" => ["request_log_id", "name", "criteria", "judge", "candidates"]},
          %{"required" => ["request_log_ids", "name", "criteria", "judge", "candidates"]},
          %{"required" => ["recording_id", "name", "criteria", "judge", "candidates"]},
          %{"required" => ["from_eval_id"]}
        ],
        "properties" => %{
          "router" => @router_arg,
          "recording_id" => %{
            "type" => "string",
            "description" =>
              "Benchmark a whole recording (see list_recordings): every replayable captured " <>
                "request becomes a source log, evenly sampled across the capture in time " <>
                "order when more than 20 are replayable. The models that served the capture " <>
                "are added as candidates automatically (include_incumbent). Takes precedence " <>
                "over request_log_id and request_log_ids."
          },
          "from_eval_id" => %{
            "type" => "string",
            "description" =>
              "Clone an existing evaluation: criteria, examples, judge, candidates, " <>
                "repetitions and the source log carry over, and any argument passed " <>
                "alongside overrides its copy. Evaluations stay immutable — this creates " <>
                "a new one."
          },
          "request_log_id" => %{
            "type" => "string",
            "description" => "An evaluable log from list_logs."
          },
          "request_log_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "maxItems" => 20,
            "description" =>
              "Evaluate a SET of logs in one benchmark: every candidate answers every log, " <>
                "and the ranking aggregates across them — the score answers \"on my " <>
                "traffic\", not \"on this one request\". Runs = logs x candidates x " <>
                "repetitions, so mind the volume. Takes precedence over request_log_id."
          },
          "name" => %{"type" => "string"},
          "criteria" => %{
            "type" => "string",
            "description" =>
              "The rubric the judge scores against. Scores are on a 0-100 scale — write " <>
                "criteria in those terms; a judge answering on another scale fails the run " <>
                "rather than being silently rescaled."
          },
          "good_examples" => %{"type" => "string"},
          "bad_examples" => %{"type" => "string"},
          "judge" => %{
            "type" => "object",
            "required" => ["provider_key_id", "model"],
            "description" => "Use a strong model; its job is harder than the candidates'.",
            "properties" => %{
              "provider_key_id" => %{"type" => "string"},
              "model" => %{"type" => "string"}
            }
          },
          "candidates" => %{
            "type" => "array",
            "description" => "Models to compare. Include your incumbent.",
            "items" => %{
              "type" => "object",
              "required" => ["provider_key_id", "model"],
              "properties" => %{
                "provider_key_id" => %{"type" => "string"},
                "model" => %{"type" => "string"}
              }
            }
          },
          "repetitions" => %{
            "type" => "integer",
            "description" =>
              "Runs per candidate, 1-10. This is your variance estimate, not a quality boost. Defaults to 3."
          },
          "prompt_variants" => %{
            "type" => "array",
            "maxItems" => 10,
            "items" => %{
              "type" => "object",
              "required" => ["name"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "system_prompt" => %{
                  "type" => ["string", "null"],
                  "description" =>
                    "Replaces the served request's system prompt (prepended if it had " <>
                      "none); null means as-served, so the baseline sits in the " <>
                      "comparison under its own name."
                },
                "message_patches" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "required" => ["index", "content"],
                    "properties" => %{
                      "index" => %{"type" => "integer", "minimum" => 0},
                      "content" => %{"type" => ["string", "array"]}
                    }
                  },
                  "description" =>
                    "Replaces the content of the message at each 0-based index of the " <>
                      "served request — e.g. swap a tool-result message for a compressed " <>
                      "version and measure whether reasoning survives. Compute the " <>
                      "transform yourself and send the result; the router never runs " <>
                      "client code. Indexes refer to the request as served (before any " <>
                      "system_prompt prepend); an index with no message behind it is " <>
                      "refused at creation, named. Same frozen history, one bit flipped."
                }
              }
            },
            "description" =>
              "Hold the model constant and vary the prompt: candidates x variants in one " <>
                "benchmark, one judge, one ranking row per (model x variant). The judge " <>
                "scores each answer against the request that run actually sent and never " <>
                "sees variant names. Runs multiply by the variant count."
          },
          "comparison_mode" => %{
            "type" => "string",
            "enum" => ["rubric", "next_action"],
            "description" =>
              "How the judge frames its verdict. \"rubric\" (default) scores each answer " <>
                "against the criteria alone. \"next_action\" is the per-decision preference " <>
                "test for recorded agent trajectories: each source log's request already " <>
                "carries the full frozen history (every real tool result), the candidate " <>
                "proposes ONE next action, and the judge compares it against what production " <>
                "actually did at that turn — better / equivalent / worse — without simulating " <>
                "anything after it. Rankings then carry a decisions rollup (\"candidate makes " <>
                "the better-or-equal move in N% of decisions\"). Requires every source log to " <>
                "have a stored, extractable response."
          },
          "run" => %{"type" => "boolean", "description" => "Start the benchmark now."},
          "include_incumbent" => %{
            "type" => "boolean",
            "description" =>
              "Default true: the model that served the source log is added as a candidate " <>
                "when absent, so every benchmark has its baseline. False leaves the " <>
                "candidate list exactly as given."
          }
        }
      }
    },
    %{
      name: "run_eval",
      title: "Run an evaluation",
      description:
        "Start or re-start the whole benchmark: every candidate, every repetition. Returns " <>
          "immediately; poll get_eval until running is false. This calls providers and spends " <>
          "money — after a partial failure prefer retry_eval, which repeats only what failed and " <>
          "re-scores stored answers for free. Refused when the judge's key is already known to be " <>
          "out of quota or failing auth, since that loses every score in the batch.",
      scopes: ["evals:write"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{
          "router" => @router_arg,
          "id" => %{"type" => "string"},
          "repetitions" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 10,
            "description" =>
              "Override repetitions per candidate for this and future runs; omitted keeps " <>
                "the evaluation's current setting."
          }
        }
      }
    },
    %{
      name: "send_feedback",
      title: "Send feedback to the DodoRouter team",
      description:
        "Tell the people who build this surface what worked and what did not — a missing " <>
          "field, a payload that blew your context, a warning that would have saved a run. " <>
          "Goes straight to the admins with your account attached; no scope required. " <>
          "This surface has been reshaped by exactly this kind of feedback before.",
      scopes: [],
      schema: %{
        "type" => "object",
        "required" => ["message"],
        "properties" => %{
          "message" => %{
            "type" => "string",
            "maxLength" => 5000,
            "description" => "What happened and what you expected. Plain text."
          }
        }
      }
    },
    %{
      name: "cancel_eval",
      title: "Cancel a running benchmark",
      description:
        "Stop a running benchmark immediately: in-flight provider calls are killed and the " <>
          "spending stops here. Unfinished runs are marked failed as cancelled; answers " <>
          "already generated stay stored, so retry_eval can still re-judge them. Errors " <>
          "when nothing is running.",
      scopes: ["evals:write"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"router" => @router_arg, "id" => %{"type" => "string"}}
      }
    },
    %{
      name: "retry_eval",
      title: "Retry only the failed runs",
      description:
        "Repeats just the failed runs of the latest batch, in place. A run whose failure_stage is " <>
          "\"judge\" is re-scored from the answer already stored — no candidate call, no second " <>
          "generation cost. A \"candidate\" failure calls that provider again for the same model. " <>
          "Prefer this over run_eval after a rate limit or an interrupted benchmark: run_eval " <>
          "re-runs everything and pays for answers you already have. Returns immediately; poll " <>
          "get_eval until running is false.",
      scopes: ["evals:write"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"router" => @router_arg, "id" => %{"type" => "string"}}
      }
    },
    %{
      name: "get_eval",
      title: "Get evaluation results",
      description: """
      Status, per-model rankings (score, latency, cost) and the judge's feedback on your own rubric.

      Read rubric_feedback before trusting the scores: if the judge often said the criteria were too thin to decide, the numbers are noise dressed up as data. A gap between two models smaller than their score_stddev is not a result.

      On a multi-log benchmark each ranking row also carries per_source — the same aggregates per source log, sorted worst-first. Read it before switching models: an average hides a candidate that is fine on 18 of 20 requests and catastrophic on 2. Pass a weak row's source_log_id to get_log to see which request breaks it.

      A recording-based benchmark adds savings_projection: each candidate's generation cost scaled to the capture's real request rate, next to what the traffic cost as served — "$X/month at your current rate", at API list prices with judge spend excluded. Absent when the capture window is under 10 minutes, because a rate measured that briefly is an artifact of when the operator clicked stop.

      applied_changes, when present, is the audit trail of routing changes made from this benchmark's verdict — what served before, what serves now, when, and whether it was reverted. Applying is the operator's click in the dashboard; these tools read the trail, they do not change routing.

      monitor, when present, is the continuous check on an applied verdict: the same rubric and judge keep scoring a few live answers per interval, and alerted_at is set while the rolling live average sits below the benchmark baseline (it clears on recovery). If alerted_at is set, the downgrade is no longer earning its evidence — say so to your operator.

      A failed run is not always a failed model. `failure_stage` says which half broke: "judge" means the answer was generated and paid for and only the scoring call failed — retry_eval re-scores it for free — while "candidate" means the model never answered. `retryable` counts both. `blockers` reports what is already known to be broken before spending anything: a key seen refusing, or a candidate model the provider has retired; it is omitted while the benchmark is running, since the keys were checked at start and a poll should stay cheap.

      The default payload is built for polling: status, summary, rankings, rubric feedback and retry counts. Pass include: ["runs"] for the per-run detail (up to 2,000 chars of output_preview per run — a full batch can be large) and include: ["criteria"] for the rubric text.
      """,
      scopes: ["evals:read"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{
          "router" => @router_arg,
          "id" => %{"type" => "string"},
          "include" => %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => ["runs", "criteria", "attempts"]},
            "description" =>
              "Extra sections beyond the polling default: \"runs\" for per-run detail " <>
                "with output previews and log ids, \"criteria\" for the rubric text, " <>
                "\"attempts\" for the superseded attempts a retry replaced (implies runs)."
          }
        }
      }
    }
  ]

  @doc "Tool definitions in MCP `tools/list` shape."
  def list(%Principal{} = principal) do
    # Every tool is listed, including ones this token cannot use. Hiding them
    # would make a 403 look like a missing feature, and an agent that can see
    # the tool plus the scope it needs can tell its user what to grant.
    Enum.map(@definitions, fn tool ->
      %{
        name: tool.name,
        title: tool.title,
        description: describe(tool, principal),
        inputSchema: tool.schema
      }
    end)
  end

  def definition(name), do: Enum.find(@definitions, &(&1.name == name))

  defp describe(%{scopes: []} = tool, _principal), do: String.trim(tool.description)

  defp describe(tool, principal) do
    if Principal.allows?(principal, tool.scopes) do
      String.trim(tool.description)
    else
      String.trim(tool.description) <>
        "\n\nUNAVAILABLE: this token is missing the #{Enum.join(tool.scopes, " ")} scope."
    end
  end

  @doc """
  Runs a tool.

  Always returns `{:ok, payload, audit_meta}` or `{:error, message}`, so the
  transport never has to know which tools happen to report audit detail. Scope
  and router checks happen here rather than in the controller, so they cannot
  be skipped by a second caller.
  """
  def call(%Principal{} = principal, name, args) when is_map(args) do
    case definition(name) do
      nil ->
        {:error, "No tool named #{name}. Call tools/list to see what exists."}

      tool ->
        if Principal.allows?(principal, tool.scopes) do
          tool.name |> run(principal, args) |> normalize()
        else
          {:error,
           "This token is missing the #{Enum.join(tool.scopes, " ")} scope, which #{name} requires."}
        end
    end
  end

  def call(principal, name, _args), do: call(principal, name, %{})

  defp normalize({:ok, payload, meta}), do: {:ok, payload, meta}
  defp normalize({:ok, payload}), do: {:ok, payload, %{}}
  defp normalize({:error, message}), do: {:error, message}

  ## Router resolution

  # Naming a router is friction when the token reaches exactly one, and a
  # source of silent mistakes when it reaches several — so it is optional in
  # the first case and required in the second, rather than defaulting to
  # "whichever came first".
  defp resolve_router(principal, args) do
    routers = Agents.routers_for(principal.user, principal)

    case {args["router"], routers} do
      {nil, [only]} ->
        {:ok, only}

      {nil, []} ->
        {:error, "This token reaches no routers."}

      {nil, many} ->
        {:error,
         "This token reaches #{length(many)} routers (#{Enum.map_join(many, ", ", & &1.slug)}), so `router` is required."}

      {slug, routers} ->
        case Enum.find(routers, &(&1.slug == slug)) do
          nil ->
            {:error,
             "No router #{slug} for this token. It reaches: #{Enum.map_join(routers, ", ", & &1.slug)}"}

          router ->
            {:ok, router}
        end
    end
  end

  ## Tools

  # Returned as one markdown string rather than decomposed into fields. It is
  # prose whose value is in the argument it makes — "include the incumbent or
  # you have no baseline" is not a parameter, and shredding it into a schema
  # would leave the caller with the parts and not the point.
  defp run("get_guide", _principal, _args), do: {:ok, %{guide: @guide}}

  defp run("list_routers", principal, _args) do
    routers = Agents.routers_for(principal.user, principal)

    {:ok,
     %{
       routers: Enum.map(routers, &%{id: &1.id, name: &1.name, slug: &1.slug}),
       reaches_all_routers: principal.all_routers,
       scopes: principal.scopes
     }}
  end

  defp run("list_logs", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, since} <- parse_time(args["since"], "since"),
         {:ok, until} <- parse_time(args["until"], "until") do
      limit = args |> Map.get("limit", 20) |> clamp(1, 100)

      filters = [
        status: presence(args["status"]),
        model: presence(args["model"]),
        provider: presence(args["provider"]),
        session_id: presence(args["session_id"]),
        recording_id: presence(args["recording_id"]),
        from: since,
        to: until
      ]

      logs = Logs.list_logs(router, [limit: limit] ++ filters)

      {:ok,
       %{
         router: router.slug,
         returned: length(logs),
         # The honest denominator: a capped page must not read as the
         # whole answer when an agent is summing costs off it.
         total: Logs.count_logs(router, filters),
         logs: Enum.map(logs, &log_summary/1)
       }}
    end
  end

  defp run("list_sessions", principal, args) do
    with {:ok, router} <- resolve_router(principal, args) do
      limit = args |> Map.get("limit", 20) |> clamp(1, 100)
      hours = args["hours"] && clamp(args["hours"], 1, 720)

      sessions = Logs.list_sessions(router, limit: limit, hours: hours)

      {:ok,
       %{
         router: router.slug,
         returned: length(sessions),
         sessions:
           Enum.map(sessions, fn session ->
             %{
               session_id: session.session_id,
               session_name: session.session_name,
               request_count: session.request_count,
               total_tokens: session.total_tokens,
               avg_latency_ms: round_ms(session.avg_latency_ms),
               last_activity: session.last_activity,
               cost_usd: money(session.total_cost_usd),
               list_cost_usd: money(session.total_list_cost_usd)
             }
           end)
       }}
    end
  end

  defp run("get_session", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, session_id} <- require_session_id(args["session_id"]) do
      # Never a 404: the aggregates cover what has been served so far, so a
      # session still in flight — or one whose first request has not landed
      # yet — answers with its current truth (zeros included) instead of
      # making the caller poll an error away.
      stats = Logs.session_stats(router, session_id)

      {:ok,
       %{
         session_id: session_id,
         request_count: stats.request_count,
         total_tokens: stats.total_tokens || 0,
         prompt_tokens: stats.prompt_tokens || 0,
         completion_tokens: stats.completion_tokens || 0,
         avg_latency_ms: round_ms(stats.avg_latency_ms),
         successful_requests: stats.successful_requests,
         error_requests: stats.error_requests,
         first_request: stats.first_request,
         last_request: stats.last_request,
         cost_usd: money(stats.total_cost_usd),
         list_cost_usd: money(stats.total_list_cost_usd),
         # What the session's input tokens were made of, summed across its
         # requests — "tool results are 60% of this question's tokens" is
         # the number that tells you what to fix.
         token_attribution: Logs.session_token_attribution(router, session_id)
       }, %{target_type: "session", target_id: session_id}}
    end
  end

  defp run("get_recording", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, recording} <- fetch_recording(principal, router, args["id"]) do
      stats = Recordings.recording_stats(recording)

      {:ok,
       %{
         id: recording.id,
         name: recording.name,
         status: recording.status,
         started_at: recording.started_at,
         stopped_at: recording.stopped_at,
         request_count: stats.request_count,
         total_tokens: stats.total_tokens || 0,
         prompt_tokens: stats.prompt_tokens || 0,
         completion_tokens: stats.completion_tokens || 0,
         avg_latency_ms: round_ms(stats.avg_latency_ms),
         successful_requests: stats.successful_requests,
         error_requests: stats.error_requests,
         cost_usd: money(stats.total_cost_usd),
         list_cost_usd: money(stats.total_list_cost_usd)
       }, %{target_type: "recording", target_id: recording.id}}
    end
  end

  defp run("get_spend", principal, args) do
    with {:ok, router} <- resolve_router(principal, args) do
      hours = args |> Map.get("hours", 24) |> clamp(1, 720)

      {:ok,
       %{
         router: router.slug,
         window_hours: hours,
         by_model:
           router
           |> Logs.spend_by_model(hours: hours)
           |> Enum.map(fn row ->
             %{
               model: row.model,
               provider: row.provider,
               requests: row.total_requests,
               total_tokens: row.total_tokens,
               cost_usd: money(row.cost_usd),
               list_cost_usd: money(row.list_cost_usd)
             }
           end)
       }}
    end
  end

  defp run("get_cache_stats", principal, args) do
    with {:ok, router} <- resolve_router(principal, args) do
      hours = args |> Map.get("hours", 24) |> clamp(1, 720)

      {:ok,
       Map.merge(
         %{router: router.slug, window_hours: hours},
         Logs.cache_stats(router, hours: hours)
       )}
    end
  end

  defp run("list_recordings", principal, args) do
    with {:ok, router} <- resolve_router(principal, args) do
      limit = args |> Map.get("limit", 20) |> clamp(1, 100)
      recordings = Recordings.list_recordings(router, limit: limit)
      counts = Recordings.log_counts(Enum.map(recordings, & &1.id))

      {:ok,
       %{
         router: router.slug,
         recordings:
           Enum.map(recordings, fn recording ->
             %{
               id: recording.id,
               name: recording.name,
               status: recording.status,
               started_at: recording.started_at,
               stopped_at: recording.stopped_at,
               request_count: Map.get(counts, recording.id, 0)
             }
           end)
       }}
    end
  end

  defp run("get_log", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, log} <- fetch_log(principal, router, args["id"]) do
      bodies? = Principal.allows?(principal, "logs:read_bodies")

      {:ok,
       log
       |> log_summary()
       |> Map.merge(%{
         request_body: body_or_marker(bodies?, log.request_body),
         response_body: body_or_marker(bodies?, log.response_body),
         truncation_flags: log.truncation_flags,
         # Input tokens bucketed by what the context is made of (system /
         # tools / history / tool_results with by_tool / file_contents) and
         # by cache position. Pro-rata allocation against the billed total,
         # not tokenizer output. nil on rows predating the feature.
         token_attribution: log.token_attribution
       }), %{returned_bodies: bodies?, target_type: "request_log", target_id: log.id}}
    end
  end

  defp run("list_eval_targets", principal, args) do
    with {:ok, _router} <- resolve_router(principal, args) do
      # The unfiltered list is every key × every catalog model (~15KB for a
      # normal account) — filterable because an agent picking one candidate
      # should not have to page the whole matrix through its context.
      targets =
        principal.user
        |> Replays.list_targets()
        |> filter_targets_by_provider(args["provider"])
        |> Enum.map(fn target ->
          %{
            provider_key_id: target.provider_key.id,
            provider: target.provider,
            provider_name: target.display_name,
            label: target.provider_key.label,
            # Subscription keys are provisioned for a vendor's own coding
            # environment and can refuse traffic from anywhere else. Fine for a
            # candidate — a refusal there is one data point — but a judge that
            # cannot answer produces no score at all.
            billing: Providers.billing(target.provider_key),
            judge_advice: judge_advice(target.provider_key),
            models:
              Enum.map(target.models, fn model ->
                %{
                  id: model[:id],
                  display_name: model[:display_name],
                  input_price_per_million: money(model[:input_price]),
                  output_price_per_million: money(model[:output_price])
                }
              end)
          }
        end)
        |> filter_targets_by_model(args["model"])

      {kept, truncated?} = limit_targets(targets, args["limit"])

      {:ok, %{targets: kept, truncated: truncated?}}
    end
  end

  defp run("list_evals", principal, args) do
    with {:ok, router} <- resolve_router(principal, args) do
      evaluations = Evaluations.list_for_router(principal.user, router.id, limit: 50)

      {:ok,
       %{
         evaluations:
           Enum.map(evaluations, fn evaluation ->
             %{
               id: evaluation.id,
               name: evaluation.name,
               status: evaluation.benchmark_status,
               run_count: evaluation.run_count,
               created_at: evaluation.inserted_at
             }
           end)
       }}
    end
  end

  defp run("create_eval", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, args} <- expand_from_eval(principal, router, args),
         {:ok, logs, recording} <- resolve_source_logs(principal, router, args),
         [log | _] = logs,
         :ok <- check_next_action_sources(args["comparison_mode"], logs),
         :ok <- check_message_patches(args["prompt_variants"], logs),
         {:ok, judge} <- judge_target(principal, args["judge"]),
         {:ok, candidates} <- candidate_targets(principal, args["candidates"]) do
      candidates = maybe_add_incumbents(principal, logs, candidates, args["include_incumbent"])

      attrs = %{
        "name" => args["name"],
        "criteria" => args["criteria"],
        "good_examples" => args["good_examples"],
        "bad_examples" => args["bad_examples"],
        "judge_provider_key_id" => judge.provider_key_id,
        "judge_model" => judge.model,
        "candidate_targets" => candidates,
        "source_log_ids" => Enum.map(logs, & &1.id),
        "recording_id" => recording && recording.id,
        "prompt_variants" => args["prompt_variants"] || [],
        "comparison_mode" => args["comparison_mode"],
        "repetitions" => args["repetitions"] || 3
      }

      case Evaluations.create_evaluation(principal.user, log, attrs) do
        {:ok, evaluation} ->
          if args["run"] == true, do: Evaluations.enqueue(principal.user, evaluation)

          {:ok, eval_payload(principal, evaluation.id),
           %{target_type: "evaluation", target_id: evaluation.id}}

        {:error, changeset} ->
          {:error, "Evaluation is invalid: #{changeset_message(changeset)}"}
      end
    end
  end

  defp run("run_eval", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, evaluation} <- fetch_eval(principal, router, args["id"]) do
      case Evaluations.enqueue(principal.user, evaluation, repetitions: args["repetitions"]) do
        :ok ->
          {:ok, eval_payload(principal, evaluation.id),
           %{target_type: "evaluation", target_id: evaluation.id}}

        {:error, :already_running} ->
          {:error, "That evaluation is already running. Poll get_eval instead of starting again."}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, "Not started: #{changeset_message(changeset)}"}

        {:error, {:judge_key_unusable, blocker}} ->
          # Refused rather than started: every candidate would be generated
          # and paid for, then thrown away for want of a judge.
          {:error,
           "Not started: the judge's key #{blocker.label} is #{blocker.status}. Every answer " <>
             "would be generated and paid for, then discarded unscored. Pick another judge key " <>
             "(list_eval_targets reports key health) and create a new evaluation."}

        {:error, {:too_many_runs, planned, max}} ->
          {:error,
           "Not started: this evaluation would perform #{planned} runs " <>
             "(logs x candidates x repetitions); the cap is #{max}. Reduce one dimension."}

        {:error, {:candidates_unusable, blockers}} ->
          named =
            Enum.map_join(blockers, "; ", fn b ->
              "#{b[:label] || b[:key_id]} / #{b[:model] || "?"} is #{b.status}"
            end)

          {:error,
           "Not started: every candidate is blocked — #{named}. Nothing could produce an " <>
             "answer, so running would only spend the judge's quota. Create a new evaluation " <>
             "with from_eval_id and working candidates (list_eval_targets reports key health)."}
      end
    end
  end

  defp run("send_feedback", principal, args) do
    message = args["message"]

    cond do
      not is_binary(message) or String.trim(message) == "" ->
        {:error, "message is required — say what happened and what you expected."}

      String.length(message) > 5000 ->
        {:error, "message is over 5,000 characters — send the essence, not the transcript."}

      true ->
        case Agents.FeedbackNotifier.deliver_feedback(principal.user.email, message) do
          {:ok, _} ->
            {:ok, %{delivered: true, note: "Thank you — this lands directly with the team."}}

          {:error, _reason} ->
            {:error, "Could not deliver the feedback right now. Please try again later."}
        end
    end
  end

  defp run("cancel_eval", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, evaluation} <- fetch_eval(principal, router, args["id"]) do
      case Evaluations.cancel_benchmark(principal.user, evaluation) do
        :ok ->
          {:ok, eval_payload(principal, evaluation.id),
           %{target_type: "evaluation", target_id: evaluation.id}}

        {:error, :not_running} ->
          {:error, "Nothing is running for that evaluation — there is nothing to cancel."}
      end
    end
  end

  defp run("retry_eval", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, evaluation} <- fetch_eval(principal, router, args["id"]) do
      case Evaluations.enqueue_retry(principal.user, evaluation) do
        :ok ->
          {:ok, eval_payload(principal, evaluation.id),
           %{target_type: "evaluation", target_id: evaluation.id}}

        {:error, :already_running} ->
          {:error, "That evaluation is already running. Poll get_eval instead of retrying now."}
      end
    end
  end

  defp run("get_eval", principal, args) do
    with {:ok, router} <- resolve_router(principal, args),
         {:ok, evaluation} <- fetch_eval(principal, router, args["id"]) do
      {:ok, eval_payload(principal, evaluation.id, include: args["include"]),
       %{
         target_type: "evaluation",
         target_id: evaluation.id,
         returned_bodies: Principal.allows?(principal, "logs:read_bodies")
       }}
    end
  end

  defp filter_targets_by_provider(targets, provider) when is_binary(provider) and provider != "",
    do: Enum.filter(targets, &(&1.provider == provider))

  defp filter_targets_by_provider(targets, _), do: targets

  defp filter_targets_by_model(targets, substring)
       when is_binary(substring) and substring != "" do
    needle = String.downcase(substring)

    targets
    |> Enum.map(fn target ->
      models =
        Enum.filter(target.models, fn model ->
          String.contains?(String.downcase(model.id || ""), needle) or
            String.contains?(String.downcase(model.display_name || ""), needle)
        end)

      %{target | models: models}
    end)
    # A key with no matching models is noise for this query, not an answer.
    |> Enum.reject(&(&1.models == []))
  end

  defp filter_targets_by_model(targets, _), do: targets

  defp limit_targets(targets, limit) when is_integer(limit) and limit > 0,
    do: {Enum.take(targets, limit), length(targets) > limit}

  defp limit_targets(targets, _), do: {targets, false}

  defp judge_advice(provider_key) do
    if Providers.subscription_key?(provider_key) do
      "Prefer a metered key for the judge: this one bills against a subscription/coding plan, which may refuse calls made outside its own coding environment."
    end
  end

  # Mirrors the web UI's shared_key_label/1 (eval_live/show.ex): the judge's
  # key label when any candidate generates through the same key, else nil.
  defp shared_judge_key_label(evaluation) do
    shared? =
      Enum.any?(evaluation.candidate_targets || [], fn target ->
        target["provider_key_id"] == evaluation.judge_provider_key_id
      end)

    if shared? and evaluation.judge_provider_key, do: evaluation.judge_provider_key.label
  end

  defp shared_key_warnings(nil), do: []

  defp shared_key_warnings(label) do
    [
      "The judge and at least one candidate share provider key \"#{label}\". Judging and " <>
        "generating through one account spends the same quota twice — if the judge gets " <>
        "rate-limited, answers are generated and paid for but never scored. Prefer a judge " <>
        "on a different (metered) key; list_eval_targets shows what is available."
    ]
  end

  ## Payloads

  # The default payload is a polling payload: get_eval blew a client's
  # tool-result limit twice when candidates x repetitions x 2,000-char
  # previews rode along on every 2-second poll (dodo_router-m4o). `runs`
  # and `criteria` come only via include:, and preflight is skipped while
  # the benchmark is running — the keys were checked at start.
  defp eval_payload(principal, id, opts \\ []) do
    evaluation = Evaluations.get_evaluation!(principal.user, id)
    runs = Evaluations.latest_batch_runs(evaluation)
    rankings = Evaluations.rankings(evaluation)
    shared_key_label = shared_judge_key_label(evaluation)
    running? = Evaluations.benchmark_running?(evaluation)
    include = opts |> Keyword.get(:include) |> List.wrap()

    payload = %{
      id: evaluation.id,
      # Judging and generating through one account is how a benchmark rate
      # limits itself: every repetition of every target spends the same quota
      # twice, and a rate-limited judge scores nothing. Knowable at creation,
      # so it is said at creation (the web UI has warned since show.ex grew
      # shared_key_label/1; this is the MCP parity — dodo_router-jzf).
      shared_judge_key_label: shared_key_label,
      warnings: shared_key_warnings(shared_key_label),
      name: evaluation.name,
      status: evaluation.benchmark_status,
      running: running?,
      repetitions: evaluation.repetitions,
      comparison_mode: DodoRouter.Logs.Evaluation.comparison_mode(evaluation),
      request_log_id: evaluation.request_log_id,
      source_log_ids: DodoRouter.Logs.Evaluation.source_log_ids(evaluation),
      # Provenance: set when the source set was sampled from a recording.
      recording_id: evaluation.recording_id,
      # logs x candidates x repetitions — the volume one run_eval buys,
      # stated before it is spent.
      planned_runs: Evaluations.planned_run_count(evaluation),
      summary:
        evaluation
        |> Evaluations.summary()
        |> Map.update!(:total_cost_usd, &money/1)
        |> Map.update!(:total_list_cost_usd, &money/1),
      rankings:
        Enum.map(rankings, fn ranking ->
          %{
            provider: ranking.provider,
            model: ranking.model,
            variant: ranking.variant,
            runs: ranking.total,
            scored: ranking.successful,
            avg_score: ranking.average,
            score_stddev: ranking.stddev,
            avg_latency_ms: ranking.avg_latency,
            avg_cost_usd: money(ranking.avg_cost)
          }
          |> maybe_put_per_source(ranking)
          |> maybe_put_decisions(ranking)
        end),
      rubric_feedback: Evaluations.rubric_feedback(runs),
      # Failed runs worth repeating, split by what has to be redone. A judge
      # retry reuses the stored answer; a candidate retry calls the provider
      # again. Feed these to retry_eval rather than re-running everything.
      retryable: Evaluations.retryable_counts(evaluation)
    }

    payload
    |> maybe_put_projection(principal, evaluation, rankings)
    |> maybe_put_applied_changes(evaluation)
    |> maybe_put_monitor(evaluation)
    |> maybe_put_blockers(principal, evaluation, running?)
    |> maybe_put_criteria(evaluation, "criteria" in include)
    # "attempts" implies runs: attempt history hangs off the run it was
    # superseded by, and history without the current state answers nothing.
    |> maybe_put_runs(
      principal,
      runs,
      "runs" in include or "attempts" in include,
      "attempts" in include
    )
  end

  # next_action mode only: how often the candidate's proposed next move was
  # at least as good as what production actually did.
  defp maybe_put_decisions(row, %{decisions: nil}), do: row
  defp maybe_put_decisions(row, ranking), do: Map.put(row, :decisions, ranking.decisions)

  # Only on multi-log benchmarks: the per-source rows answer "fine on 18 of
  # the 20 requests, catastrophic on 2", which the aggregate average hides.
  # Absent (not empty) on single-source benchmarks, where the aggregate
  # already is the per-source answer.
  defp maybe_put_per_source(row, %{per_source: []}), do: row

  defp maybe_put_per_source(row, ranking) do
    Map.put(
      row,
      :per_source,
      Enum.map(ranking.per_source, fn source ->
        %{
          source_log_id: source.source_log_id,
          avg_score: source.average,
          min_score: source.min,
          scored: source.successful,
          runs: source.total
        }
      end)
    )
  end

  # Only on recording-based benchmarks: the capture's window and request
  # count give the projection its denominator, which a hand-picked log set
  # does not have. Absent when the window is too short to trust or the
  # recording is gone — a missing projection is honest, a garbage rate
  # dressed as $/month is not.
  defp maybe_put_projection(payload, _principal, %{recording_id: nil}, _rankings), do: payload

  defp maybe_put_projection(payload, principal, evaluation, rankings) do
    with %{} = recording <- Recordings.get_recording(principal.user, evaluation.recording_id),
         stats = Recordings.recording_stats(recording),
         {:ok, projection} <- Evaluations.savings_projection(rankings, recording, stats) do
      Map.put(payload, :savings_projection, %{
        monthly_requests: projection.monthly_requests,
        captured_requests: projection.captured_requests,
        window_seconds: projection.window_seconds,
        baseline_monthly_cost_usd: money(projection.baseline_monthly_cost),
        note: "Costs at API list prices; judge spend excluded — production does not pay a judge.",
        rows:
          Enum.map(projection.rows, fn row ->
            %{
              provider: row.provider,
              model: row.model,
              variant: row.variant,
              avg_score: row.avg_score,
              projected_monthly_cost_usd: money(row.projected_monthly_cost),
              monthly_savings_usd: money(row.monthly_savings)
            }
          end)
      })
    else
      _ -> payload
    end
  end

  # Whether this benchmark's verdict has been acted on. Applying is the
  # operator's click in the dashboard — these tools read the audit trail,
  # they do not change routing.
  defp maybe_put_applied_changes(payload, evaluation) do
    case Evaluations.list_applied_changes(evaluation) do
      [] ->
        payload

      events ->
        Map.put(
          payload,
          :applied_changes,
          Enum.map(events, fn event ->
            %{
              applied_at: event.inserted_at,
              reverted_at: event.reverted_at,
              batch_id: event.batch_id,
              routing_step_id: event.routing_step_id,
              before: event.before_step,
              after: event.after_step
            }
          end)
        )
    end
  end

  # The continuous check that keeps an applied downgrade honest. Read-only
  # here, like applied_changes: enabling costs judge money on a schedule,
  # which is the operator's call in the dashboard.
  defp maybe_put_monitor(payload, evaluation) do
    case Evaluations.get_monitor(evaluation) do
      nil ->
        payload

      monitor ->
        scores = Evaluations.monitor_window_scores(monitor)

        Map.put(payload, :monitor, %{
          status: monitor.status,
          target_model: monitor.target_model,
          baseline_avg: monitor.baseline_avg,
          baseline_stddev: monitor.baseline_stddev,
          recent_scores: scores,
          sample_size: monitor.sample_size,
          interval_hours: monitor.interval_hours,
          last_sampled_at: monitor.last_sampled_at,
          consecutive_drops: monitor.consecutive_drops,
          # Set while live scores sit a tolerance below the benchmark's
          # baseline; clears on recovery.
          alerted_at: monitor.alerted_at
        })
    end
  end

  # Problems knowable before spending anything: a key the proxy has seen
  # refuse, or a model the provider retired. Skipped while running — a
  # poll should not re-do key-health work the start already did.
  defp maybe_put_blockers(payload, _principal, _evaluation, true), do: payload

  defp maybe_put_blockers(payload, principal, evaluation, false) do
    Map.put(
      payload,
      :blockers,
      blockers_payload(Evaluations.preflight(principal.user, evaluation))
    )
  end

  defp maybe_put_criteria(payload, _evaluation, false), do: payload

  defp maybe_put_criteria(payload, evaluation, true),
    do: Map.put(payload, :criteria, evaluation.criteria)

  defp maybe_put_runs(payload, _principal, _runs, false, _attempts?), do: payload

  defp maybe_put_runs(payload, principal, runs, true, attempts?) do
    bodies? = Principal.allows?(principal, "logs:read_bodies")

    Map.put(
      payload,
      :runs,
      Enum.map(runs, fn run ->
        %{
          status: run.status,
          model: run.candidate_model,
          # What the provider's response claimed actually answered. A
          # mismatch is a provider-side alias/snapshot resolution — the
          # ranking is keyed on `model`, so this is the receipt that says
          # whether that is still the thing being measured.
          served_model: run.candidate_served_model,
          served_model_mismatch:
            is_binary(run.candidate_served_model) and
              run.candidate_served_model != run.candidate_model,
          score: run.score,
          criterion_scores: run.criterion_scores,
          summary: run.summary,
          issues: run.issues,
          error: run.error,
          # Stable token (rate_limited, provider_key_missing, crashed, …)
          # so a client decides whether retrying helps without regexing
          # the prose. Nil on runs recorded before it existed.
          error_category: run.error_category,
          # Which half failed. "judge" means the answer exists and was paid
          # for and only the scoring call failed, so retry_eval re-scores it
          # without generating anything; "candidate" means there is no
          # answer to score.
          failure_stage: run.failure_stage,
          latency_ms: run.candidate_latency_ms,
          cost_usd: money(run.candidate_cost_usd),
          # The credentials that actually produced this run, which are not
          # necessarily the ones the evaluation names now.
          judged_by: run.judge_provider_key_label,
          judge_key_deleted: Evaluations.judge_key_deleted?(run),
          judge_log_id: run.judge_log_id,
          answered_by: run.candidate_provider_key_label,
          candidate_key_deleted: Evaluations.candidate_key_deleted?(run),
          candidate_log_id: run.candidate_log_id,
          output_preview: body_or_marker(bodies?, truncate(run.candidate_output))
        }
        |> maybe_put_attempts(run, attempts?)
      end)
    )
  end

  # The attempts a retry replaced — "did this model fail the first time
  # too?" answered without the web UI (dodo_router-2y9). Compact on
  # purpose: history explains the current run, it does not compete with it.
  defp maybe_put_attempts(run_map, _run, false), do: run_map

  defp maybe_put_attempts(run_map, run, true) do
    Map.put(
      run_map,
      :previous_attempts,
      Enum.map(Evaluations.previous_attempts(run), fn attempt ->
        %{
          status: attempt.status,
          score: attempt.score,
          error: attempt.error,
          error_category: attempt.error_category,
          failure_stage: attempt.failure_stage,
          superseded_at: attempt.superseded_at
        }
      end)
    )
  end

  defp blockers_payload(%{judge: judge, candidates: candidates}) do
    %{
      judge: judge && Map.take(judge, [:label, :status, :detail]),
      candidates: Enum.map(candidates, &Map.take(&1, [:model, :label, :status]))
    }
  end

  defp log_summary(log) do
    blocker = Replays.replay_blocker(log)

    %{
      id: log.id,
      request_id: log.request_id,
      status: log.status,
      provider: log.final_provider,
      model: log.final_model,
      call_type: log.call_type,
      prompt_tokens: log.prompt_tokens,
      completion_tokens: log.completion_tokens,
      total_tokens: log.total_tokens,
      cache_read_tokens: log.cache_read_tokens,
      session_id: log.session_id,
      latency_ms: log.latency_ms,
      cost_usd: money(log.estimated_cost_usd),
      list_cost_usd: money(log.list_cost_usd),
      created_at: log.inserted_at,
      evaluable: is_nil(blocker),
      not_evaluable_because: blocker && to_string(blocker)
    }
  end

  ## Lookups

  defp fetch_log(principal, router, id) when is_binary(id) do
    log =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          Logs.get_log(principal.user, uuid) || Logs.get_log_by_request_id(principal.user, uuid)

        :error ->
          nil
      end

    case log do
      %{router_id: router_id} = log when router_id == router.id -> {:ok, log}
      _ -> {:error, "No log #{id} on router #{router.slug}."}
    end
  end

  defp fetch_log(_principal, _router, _id), do: {:error, "A log id is required."}

  defp require_session_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp require_session_id(_id), do: {:error, "A session_id is required."}

  defp parse_time(value, _name) when value in [nil, ""], do: {:ok, nil}

  defp parse_time(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error,
         "#{name} must be an ISO 8601 timestamp (e.g. 2026-08-16T00:00:00Z), got #{inspect(value)}."}
    end
  end

  defp parse_time(_value, name), do: {:error, "#{name} must be an ISO 8601 timestamp string."}

  # avg() comes back as a Decimal; a latency reads as whole milliseconds.
  defp round_ms(nil), do: nil
  defp round_ms(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp round_ms(value) when is_number(value), do: round(value)

  defp fetch_eval(principal, router, id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %{request_log: %{router_id: router_id}} = evaluation <-
           Evaluations.get_evaluation(principal.user, uuid),
         true <- router_id == router.id do
      {:ok, evaluation}
    else
      _ -> {:error, "No evaluation #{id} on router #{router.slug}."}
    end
  end

  defp fetch_eval(_principal, _router, _id), do: {:error, "An evaluation id is required."}

  defp evaluable(log) do
    case Replays.replay_blocker(log) do
      nil -> :ok
      reason -> {:error, "That log cannot be replayed (#{reason}), so it cannot be evaluated."}
    end
  end

  defp judge_target(principal, %{"provider_key_id" => key_id, "model" => model})
       when is_binary(key_id) and is_binary(model) do
    case provider_key(principal, key_id) do
      nil -> {:error, "judge provider_key_id #{key_id} is not one of your provider keys."}
      _key -> {:ok, %{provider_key_id: key_id, model: model}}
    end
  end

  defp judge_target(_principal, _judge),
    do: {:error, "judge must be an object with provider_key_id and model."}

  # The three source shapes, strongest first: a recording (production
  # traffic nobody hand-picked, sampled by Evaluations), a set of logs,
  # one log. Returns the recording alongside the logs so provenance is
  # recorded on the evaluation.
  defp resolve_source_logs(principal, router, %{"recording_id" => id}) when is_binary(id) do
    with {:ok, recording} <- fetch_recording(principal, router, id) do
      case Evaluations.source_logs_from_recording(recording) do
        %{selected: [], total: 0} ->
          {:error, "Recording #{id} has captured no requests yet."}

        %{selected: [], excluded: excluded} ->
          reasons = Enum.map_join(excluded, ", ", fn {reason, count} -> "#{count} #{reason}" end)

          {:error, "None of recording #{id}'s captured requests can be replayed (#{reasons})."}

        %{selected: logs} ->
          {:ok, logs, recording}
      end
    end
  end

  defp resolve_source_logs(principal, router, args) do
    with {:ok, ids} <- source_log_ids(args),
         {:ok, logs} <- fetch_evaluable_logs(principal, router, ids) do
      {:ok, logs, nil}
    end
  end

  # next_action mode judges the candidate against what production actually
  # did, so a source log with no extractable recorded action would leave
  # the judge comparing against nothing — refused up front, log named.
  defp check_next_action_sources("next_action", logs) do
    case Enum.find(logs, &Evaluations.next_action_blocker/1) do
      nil ->
        :ok

      log ->
        {:error,
         "Log #{log.id}: its stored response has no extractable action, so next_action " <>
           "mode has nothing to compare the candidate against."}
    end
  end

  defp check_next_action_sources(_mode, _logs), do: :ok

  # A patch whose index points past a log's messages would fail minutes
  # into the spend — dry-run every (variant x log) pair up front and name
  # the mismatch, same principle as the evaluability check.
  defp check_message_patches(variants, logs) when is_list(variants) do
    pairs =
      for variant <- variants,
          patches = variant["message_patches"],
          is_list(patches) and patches != [],
          log <- logs,
          do: {variant, patches, log}

    Enum.find_value(pairs, :ok, fn {variant, patches, log} ->
      case Replays.prepare_request(log, "replay-probe", nil, nil, message_patches: patches) do
        {:ok, _request} ->
          nil

        {:error, reason} ->
          {:error,
           "Variant #{inspect(variant["name"])} cannot patch log #{log.id}: #{reason}. " <>
             "Patch indexes are 0-based into that log's messages array as served."}
      end
    end)
  end

  defp check_message_patches(_variants, _logs), do: :ok

  defp fetch_recording(principal, router, id) do
    case Recordings.get_recording(principal.user, id) do
      %{router_id: router_id} = recording when router_id == router.id ->
        {:ok, recording}

      _ ->
        {:error, "No recording #{id} on router #{router.slug}. Use list_recordings to see them."}
    end
  end

  # One benchmark over a set of logs answers "on my traffic"; the single-log
  # form stays as the common case (dodo_router-3hr).
  defp source_log_ids(%{"request_log_ids" => ids}) when is_list(ids) and ids != [] do
    if length(ids) <= 20,
      do: {:ok, Enum.uniq(ids)},
      else: {:error, "request_log_ids is capped at 20 logs per evaluation."}
  end

  defp source_log_ids(%{"request_log_id" => id}) when is_binary(id), do: {:ok, [id]}

  defp source_log_ids(_args),
    do: {:error, "Provide request_log_id, request_log_ids, or from_eval_id."}

  # Every log of the set is checked the way the single log always was:
  # owned, on this router, and replayable — refused up front with the log
  # named, not minutes into the spend.
  defp fetch_evaluable_logs(principal, router, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, log} <- fetch_log(principal, router, id),
           :ok <- evaluable(log) do
        {:cont, {:ok, acc ++ [log]}}
      else
        {:error, message} -> {:halt, {:error, "Log #{id}: #{message}"}}
      end
    end)
  end

  # Evaluations are immutable on purpose — a changed rubric is a different
  # benchmark. from_eval_id keeps that while sparing the caller from
  # re-sending kilobytes of identical rubric: every field of the source
  # carries over, and any argument passed alongside overrides its copy
  # (dodo_router-z8b).
  defp expand_from_eval(principal, router, %{"from_eval_id" => id} = args)
       when is_binary(id) do
    with {:ok, source} <- fetch_eval(principal, router, id) do
      {:ok,
       args
       |> Map.put_new("request_log_id", source.request_log_id)
       |> Map.put_new("request_log_ids", DodoRouter.Logs.Evaluation.source_log_ids(source))
       |> Map.put_new("prompt_variants", source.prompt_variants || [])
       |> Map.put_new("comparison_mode", source.comparison_mode)
       |> Map.put_new("name", source.name)
       |> Map.put_new("criteria", source.criteria)
       |> Map.put_new("good_examples", source.good_examples)
       |> Map.put_new("bad_examples", source.bad_examples)
       |> Map.put_new("repetitions", source.repetitions)
       |> Map.put_new("judge", %{
         "provider_key_id" => source.judge_provider_key_id,
         "model" => source.judge_model
       })
       |> Map.put_new(
         "candidates",
         Enum.map(source.candidate_targets, &Map.take(&1, ["provider_key_id", "model"]))
       )}
    end
  end

  defp expand_from_eval(_principal, _router, args), do: {:ok, args}

  # A benchmark without the incumbent has numbers but no baseline, and the
  # source logs already name what served them — so the caller should not
  # have to remember. A multi-log set (a recording especially) can span
  # models, so every distinct serving pair is considered, not just the
  # first log's. Appended only when that incumbent model is absent, the
  # serving key is known, and it is still one of the caller's keys;
  # include_incumbent: false opts out (dodo_router-sdc).
  defp maybe_add_incumbents(_principal, _logs, candidates, false), do: candidates

  defp maybe_add_incumbents(principal, logs, candidates, _default_true) do
    logs
    |> Enum.map(&Replays.incumbent_target/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.model)
    |> Enum.reduce(candidates, fn incumbent, acc ->
      with false <- Enum.any?(acc, &(&1["model"] == incumbent.model)),
           key when not is_nil(key) <- provider_key(principal, incumbent.provider_key_id) do
        acc ++
          [
            %{
              "provider_key_id" => key.id,
              "provider" => Registry.adapter_provider(key.provider_slug),
              "model" => incumbent.model
            }
          ]
      else
        _ -> acc
      end
    end)
  end

  defp candidate_targets(principal, candidates) when is_list(candidates) and candidates != [] do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case candidate do
        %{"provider_key_id" => key_id, "model" => model}
        when is_binary(key_id) and is_binary(model) ->
          case provider_key(principal, key_id) do
            nil ->
              {:halt, {:error, "candidate provider_key_id #{key_id} is not one of your keys."}}

            key ->
              {:cont,
               {:ok,
                acc ++
                  [
                    %{
                      "provider_key_id" => key.id,
                      "provider" => Registry.adapter_provider(key.provider_slug),
                      "model" => model
                    }
                  ]}}
          end

        other ->
          {:halt,
           {:error, "each candidate needs provider_key_id and model, got #{inspect(other)}"}}
      end
    end)
  end

  defp candidate_targets(_principal, _candidates),
    do: {:error, "candidates must be a non-empty list of {provider_key_id, model}."}

  defp provider_key(principal, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Providers.get_provider_key(principal.user, uuid)
      :error -> nil
    end
  end

  ## Helpers

  defp body_or_marker(true, value), do: decode(value)
  defp body_or_marker(false, _value), do: %{withheld: "requires the logs:read_bodies scope"}

  defp decode(nil), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp truncate(nil), do: nil

  defp truncate(text) when is_binary(text) do
    if String.length(text) <= @output_preview,
      do: text,
      else: String.slice(text, 0, @output_preview) <> "… [truncated]"
  end

  defp money(nil), do: nil
  defp money(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp money(value) when is_number(value), do: value

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, _min, default), do: default

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
  end
end
