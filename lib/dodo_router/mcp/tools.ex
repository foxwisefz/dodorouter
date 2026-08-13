defmodule DodoRouter.MCP.Tools do
  @moduledoc """
  The tools an agent can call over MCP, and what they do.

  Kept separate from the transport so the interesting half — which scope a tool
  needs, what it returns, how a router argument is resolved — is testable
  without constructing JSON-RPC envelopes.

  These call the same contexts the REST surface does rather than calling the
  REST surface itself. The MCP server runs in-process; going out over HTTP to
  our own API would buy nothing and add a hop that can fail on its own.
  """

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Principal
  alias DodoRouter.{Evaluations, Logs, Providers, Replays}
  alias DodoRouter.Proxy.Adapter.Registry

  @output_preview 2_000

  @router_arg %{
    "type" => "string",
    "description" =>
      "Router slug. Optional when this token reaches exactly one router; required otherwise. Use list_routers to see them."
  }

  @definitions [
    %{
      name: "list_routers",
      title: "List routers",
      description:
        "Every router this token can reach. Start here — most other tools take a router slug.",
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
        "Provider keys and the models each can serve, with list prices per million tokens. A candidate is a provider_key_id plus a model.",
      scopes: ["evals:read"],
      schema: %{
        "type" => "object",
        "properties" => %{"router" => @router_arg}
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
        "Start or re-start the benchmark. Returns immediately; poll get_eval until running is false. This calls providers and spends money.",
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
      targets =
        principal.user
        |> Replays.list_targets()
        |> Enum.map(fn target ->
          %{
            provider_key_id: target.provider_key.id,
            provider: target.provider,
            provider_name: target.display_name,
            label: target.provider_key.label,
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

      {:ok, %{targets: targets}}
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

  ## Payloads

  defp eval_payload(principal, id) do
    evaluation = Evaluations.get_evaluation!(principal.user, id)
    runs = Evaluations.latest_batch_runs(evaluation)
    bodies? = Principal.allows?(principal, "logs:read_bodies")

    %{
      id: evaluation.id,
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
      runs:
        Enum.map(runs, fn run ->
          %{
            status: run.status,
            model: run.candidate_model,
            score: run.score,
            summary: run.summary,
            issues: run.issues,
            error: run.error,
            latency_ms: run.candidate_latency_ms,
            cost_usd: money(run.candidate_cost_usd),
            output_preview: body_or_marker(bodies?, truncate(run.candidate_output))
          }
        end)
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
