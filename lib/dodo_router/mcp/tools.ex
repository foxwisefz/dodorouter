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
  alias DodoRouter.{Evaluations, Logs, Providers, Replays}
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
        "Recent requests this router served, with model, tokens, cost and latency. `evaluable` says whether a request can be replayed into an evaluation.",
      scopes: ["logs:read"],
      schema: %{
        "type" => "object",
        "properties" => %{
          "router" => @router_arg,
          "limit" => %{"type" => "integer", "description" => "Max 100. Defaults to 20."},
          "status" => %{"type" => "string", "description" => "success, fallback or error."},
          "model" => %{"type" => "string", "description" => "Filter by served model."}
        }
      }
    },
    %{
      name: "get_log",
      title: "Get one request",
      description:
        "One request in full. Prompt and response text requires the logs:read_bodies scope; without it those fields come back marked as withheld rather than missing.",
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
      Replay one real request against several models and score the answers with a judge model.

      Include the model you use today as a candidate — a score only means something next to another score from the same rubric and judge. Write criteria that can fail: name the facts that must be right, the format, the length, and what must not appear. Set run=true to start it immediately.

      Pick a judge on a metered API key, not a subscription/coding-plan key. Plan credentials are issued for a vendor's own coding environment and may refuse or throttle calls made from anywhere else — as a candidate that costs you one data point, but as the judge it means no scores at all. list_eval_targets reports `billing` per key.

      Avoid putting the judge on the same provider key as a candidate: judging and generating through one account spends the same quota twice, and a rate-limited judge scores nothing. The result carries a warning (`shared_judge_key_label` / `warnings`) when this is the case.
      """,
      scopes: ["evals:write"],
      schema: %{
        "type" => "object",
        "required" => ["request_log_id", "name", "criteria", "judge", "candidates"],
        "properties" => %{
          "router" => @router_arg,
          "request_log_id" => %{
            "type" => "string",
            "description" => "An evaluable log from list_logs."
          },
          "name" => %{"type" => "string"},
          "criteria" => %{
            "type" => "string",
            "description" => "The rubric the judge scores against."
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
          "run" => %{"type" => "boolean", "description" => "Start the benchmark now."}
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

      A failed run is not always a failed model. `failure_stage` says which half broke: "judge" means the answer was generated and paid for and only the scoring call failed — retry_eval re-scores it for free — while "candidate" means the model never answered. `retryable` counts both. `blockers` reports what is already known to be broken before spending anything: a key seen refusing, or a candidate model the provider has retired.
      """,
      scopes: ["evals:read"],
      schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"router" => @router_arg, "id" => %{"type" => "string"}}
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
    with {:ok, router} <- resolve_router(principal, args) do
      limit = args |> Map.get("limit", 20) |> clamp(1, 100)

      logs =
        Logs.list_logs(router,
          limit: limit,
          status: presence(args["status"]),
          model: presence(args["model"])
        )

      {:ok, %{router: router.slug, returned: length(logs), logs: Enum.map(logs, &log_summary/1)}}
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
         truncation_flags: log.truncation_flags
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
         {:ok, log} <- fetch_log(principal, router, args["request_log_id"]),
         :ok <- evaluable(log),
         {:ok, judge} <- judge_target(principal, args["judge"]),
         {:ok, candidates} <- candidate_targets(principal, args["candidates"]) do
      attrs = %{
        "name" => args["name"],
        "criteria" => args["criteria"],
        "good_examples" => args["good_examples"],
        "bad_examples" => args["bad_examples"],
        "judge_provider_key_id" => judge.provider_key_id,
        "judge_model" => judge.model,
        "candidate_targets" => candidates,
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
      case Evaluations.enqueue(principal.user, evaluation) do
        :ok ->
          {:ok, eval_payload(principal, evaluation.id),
           %{target_type: "evaluation", target_id: evaluation.id}}

        {:error, :already_running} ->
          {:error, "That evaluation is already running. Poll get_eval instead of starting again."}

        {:error, {:judge_key_unusable, blocker}} ->
          # Refused rather than started: every candidate would be generated
          # and paid for, then thrown away for want of a judge.
          {:error,
           "Not started: the judge's key #{blocker.label} is #{blocker.status}. Every answer " <>
             "would be generated and paid for, then discarded unscored. Pick another judge key " <>
             "(list_eval_targets reports key health) and create a new evaluation."}
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
      {:ok, eval_payload(principal, evaluation.id),
       %{
         target_type: "evaluation",
         target_id: evaluation.id,
         returned_bodies: Principal.allows?(principal, "logs:read_bodies")
       }}
    end
  end

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

  defp eval_payload(principal, id) do
    evaluation = Evaluations.get_evaluation!(principal.user, id)
    runs = Evaluations.latest_batch_runs(evaluation)
    bodies? = Principal.allows?(principal, "logs:read_bodies")
    shared_key_label = shared_judge_key_label(evaluation)

    %{
      id: evaluation.id,
      # Judging and generating through one account is how a benchmark rate
      # limits itself: every repetition of every target spends the same quota
      # twice, and a rate-limited judge scores nothing. Knowable at creation,
      # so it is said at creation (the web UI has warned since show.ex grew
      # shared_key_label/1; this is the MCP parity — dodo_router-jzf).
      shared_judge_key_label: shared_key_label,
      warnings: shared_key_warnings(shared_key_label),
      name: evaluation.name,
      criteria: evaluation.criteria,
      status: evaluation.benchmark_status,
      running: Evaluations.benchmark_running?(evaluation),
      repetitions: evaluation.repetitions,
      request_log_id: evaluation.request_log_id,
      summary:
        evaluation
        |> Evaluations.summary()
        |> Map.update!(:total_cost_usd, &money/1)
        |> Map.update!(:total_list_cost_usd, &money/1),
      rankings:
        Enum.map(Evaluations.rankings(evaluation), fn ranking ->
          %{
            provider: ranking.provider,
            model: ranking.model,
            runs: ranking.total,
            scored: ranking.successful,
            avg_score: ranking.average,
            score_stddev: ranking.stddev,
            avg_latency_ms: ranking.avg_latency,
            avg_cost_usd: money(ranking.avg_cost)
          }
        end),
      rubric_feedback: Evaluations.rubric_feedback(runs),
      # Failed runs worth repeating, split by what has to be redone. A judge
      # retry reuses the stored answer; a candidate retry calls the provider
      # again. Feed these to retry_eval rather than re-running everything.
      retryable: Evaluations.retryable_counts(evaluation),
      # Problems knowable before spending anything: a key the proxy has seen
      # refuse, or a model the provider retired.
      blockers: blockers_payload(Evaluations.preflight(principal.user, evaluation)),
      runs:
        Enum.map(runs, fn run ->
          %{
            status: run.status,
            model: run.candidate_model,
            score: run.score,
            criterion_scores: run.criterion_scores,
            summary: run.summary,
            issues: run.issues,
            error: run.error,
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
        end)
    }
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
