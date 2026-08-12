defmodule DodoRouterWeb.EvalsController do
  @moduledoc """
  Create, run and read evaluations from an agent, using the router's API key.

  The whole surface exists so a coding agent working on a product can answer
  "what does this call cost me, and what do I lose if I serve it with a
  cheaper model?" without a human in the loop: pick a real request the product
  made, name the criteria, list the models to try, and read back a score and a
  price per candidate.

  `GET /r/:router_slug/agent` describes the loop in prose for a caller that has
  the base URL and a key and nothing else.
  """

  use DodoRouterWeb, :controller

  import DodoRouterWeb.AgentApi
  import DodoRouterWeb.Plugs.AgentAuth, only: [require_scopes: 2]

  alias DodoRouter.{Evaluations, Logs, Providers, Replays}
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouterWeb.Plugs.AgentAudit

  # `guide` is documentation and needs no scope beyond a valid credential —
  # an agent that cannot read the instructions cannot discover what it may do.
  plug :require_scopes, ["evals:read"] when action in [:targets, :index, :show]
  plug :require_scopes, ["evals:write"] when action in [:create, :run]

  # The full text of a candidate answer is on its own log; inline it only far
  # enough to see what happened at a glance.
  @output_preview 2_000

  # Read at compile time from the source tree rather than `priv` at runtime:
  # the guide has to be there for a release too, and a missing file should
  # fail the build, not the first agent that asks for it.
  @guide_path Path.expand("../../../priv/agent/evals_guide.md", __DIR__)
  @external_resource @guide_path
  @guide File.read!(@guide_path)

  @endpoints [
    %{
      method: "GET",
      path: "/agent",
      summary: "This guide, plus the endpoint list."
    },
    %{
      method: "GET",
      path: "/logs",
      summary:
        "Recent requests this router served. Filters: limit, offset, status, provider, model, call_type, favorites_only."
    },
    %{
      method: "GET",
      path: "/logs/:id",
      summary: "One request, with its stored request and response bodies. Accepts a request_id."
    },
    %{
      method: "GET",
      path: "/evals/targets",
      summary: "Provider keys and models you can use as candidates or as the judge, with prices."
    },
    %{
      method: "GET",
      path: "/evals",
      summary: "Evaluations created against this router's logs. Filters: limit, offset."
    },
    %{
      method: "POST",
      path: "/evals",
      summary: "Create an evaluation. Pass run=true to start it."
    },
    %{
      method: "GET",
      path: "/evals/:id",
      summary: "Status, per-model rankings, judge feedback on your rubric, and the runs."
    },
    %{method: "POST", path: "/evals/:id/run", summary: "Run (or re-run) the benchmark."}
  ]

  def guide(conn, _params) do
    base = "#{DodoRouterWeb.Endpoint.url()}/r/#{router_slug(conn)}"

    json(conn, %{
      router: %{slug: router_slug(conn), name: conn.assigns.current_router.name},
      base_url: base,
      guide:
        @guide
        |> String.replace("{{BASE}}", base)
        |> String.replace("{{SLUG}}", router_slug(conn)),
      endpoints: Enum.map(@endpoints, &Map.put(&1, :url, base <> &1.path))
    })
  end

  def targets(conn, _params) do
    data =
      conn
      |> current_user()
      |> Replays.list_targets()
      |> Enum.map(fn target ->
        %{
          provider_key_id: target.provider_key.id,
          provider: target.provider,
          provider_slug: target.provider_key.provider_slug,
          provider_name: target.display_name,
          label: target.provider_key.label,
          models: Enum.map(target.models, &model_entry/1)
        }
      end)

    json(conn, %{data: data})
  end

  def index(conn, params) do
    {limit, offset} = paging(params)

    evaluations =
      conn
      |> current_user()
      |> Evaluations.list_for_router(conn.assigns.current_router.id,
        limit: limit,
        offset: offset
      )

    json(conn, %{
      data: Enum.map(evaluations, &listing/1),
      limit: limit,
      offset: offset,
      returned: length(evaluations)
    })
  end

  def create(conn, params) do
    user = current_user(conn)
    router = conn.assigns.current_router

    with {:ok, log} <-
           fetch_source_log(user, router, params["request_log_id"] || params["log_id"]),
         {:ok, judge} <- fetch_judge(user, params),
         {:ok, candidates} <- fetch_candidates(user, params) do
      attrs = %{
        "name" => params["name"],
        "criteria" => params["criteria"],
        "good_examples" => params["good_examples"],
        "bad_examples" => params["bad_examples"],
        "judge_provider_key_id" => judge.provider_key_id,
        "judge_model" => judge.model,
        "candidate_targets" => candidates,
        "repetitions" => params["repetitions"] || 3
      }

      case Evaluations.create_evaluation(user, log, attrs) do
        {:ok, evaluation} ->
          maybe_run(user, evaluation, params["run"] in [true, "true", "1"])

          conn
          |> AgentAudit.annotate(target_type: "evaluation", target_id: evaluation.id)
          |> put_status(201)
          |> json(show_payload(conn, user, evaluation.id))

        {:error, changeset} ->
          error(conn, 422, "Evaluation is invalid", "invalid_request_error", %{
            details: changeset_errors(changeset)
          })
      end
    else
      {:error, status, message} -> error(conn, status, message, error_type(status))
    end
  end

  def show(conn, %{"id" => id}) do
    user = current_user(conn)

    case scoped_evaluation(conn, user, id) do
      {:ok, evaluation} ->
        conn
        |> AgentAudit.annotate(
          target_type: "evaluation",
          target_id: evaluation.id,
          returned_bodies: may_read_bodies?(conn)
        )
        |> json(show_payload(conn, user, evaluation.id))

      {:error, message} ->
        error(conn, 404, message, "not_found")
    end
  end

  def run(conn, %{"id" => id}) do
    user = current_user(conn)

    case scoped_evaluation(conn, user, id) do
      {:ok, evaluation} ->
        case Evaluations.enqueue(user, evaluation) do
          :ok ->
            fresh = Evaluations.get_evaluation!(user, evaluation.id)

            conn
            |> put_status(202)
            |> json(%{
              evaluation_id: fresh.id,
              status: fresh.benchmark_status,
              running: Evaluations.benchmark_running?(fresh),
              runs_queued: length(fresh.candidate_targets) * fresh.repetitions
            })

          {:error, :already_running} ->
            error(conn, 409, "This evaluation is already running", "conflict")
        end

      {:error, message} ->
        error(conn, 404, message, "not_found")
    end
  end

  ## Lookups

  # The API key names a router, so an evaluation reached through it has to be
  # anchored to a log of that router — otherwise one product's key would read
  # another product's results.
  defp scoped_evaluation(conn, user, id) do
    router_id = conn.assigns.current_router.id

    with {:ok, uuid} <- uuid(id),
         %{request_log: %{router_id: ^router_id}} = evaluation <-
           Evaluations.get_evaluation(user, uuid) do
      {:ok, evaluation}
    else
      _ -> {:error, "No evaluation #{id} on router #{conn.assigns.current_router.slug}"}
    end
  end

  defp fetch_source_log(_user, _router, nil),
    do: {:error, 422, "request_log_id is required — list candidates with GET /logs"}

  defp fetch_source_log(user, router, id) do
    log =
      case uuid(id) do
        {:ok, uuid} -> Logs.get_log(user, uuid) || Logs.get_log_by_request_id(user, uuid)
        :error -> nil
      end

    case log do
      %{router_id: router_id} = log when router_id == router.id ->
        case Replays.replay_blocker(log) do
          nil -> {:ok, log}
          reason -> {:error, 422, "Log #{id} cannot be replayed: #{blocker_reason(reason)}"}
        end

      _ ->
        {:error, 404, "No log #{id} on router #{router.slug}"}
    end
  end

  defp fetch_judge(user, params) do
    judge = params["judge"] || %{}

    key_id = judge["provider_key_id"] || params["judge_provider_key_id"]
    model = judge["model"] || params["judge_model"]

    cond do
      is_nil(key_id) or is_nil(model) ->
        {:error, 422,
         "judge must name a provider_key_id and a model — list them with GET /evals/targets"}

      is_nil(provider_key(user, key_id)) ->
        {:error, 422, "judge provider_key_id #{key_id} is not one of your provider keys"}

      true ->
        {:ok, %{provider_key_id: key_id, model: model}}
    end
  end

  defp fetch_candidates(user, params) do
    case params["candidates"] || params["candidate_targets"] do
      list when is_list(list) and list != [] ->
        Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
          case candidate_target(user, entry) do
            {:ok, target} -> {:cont, {:ok, acc ++ [target]}}
            {:error, message} -> {:halt, {:error, 422, message}}
          end
        end)

      _ ->
        {:error, 422,
         "candidates must be a non-empty list of {provider_key_id, model} — list them with GET /evals/targets"}
    end
  end

  # The stored target needs the adapter's provider name as well as the key,
  # but that is derivable from the key — asking a caller for it invites the
  # two to disagree, and the pair is what routing is keyed on.
  defp candidate_target(user, %{"provider_key_id" => key_id, "model" => model})
       when is_binary(key_id) and is_binary(model) and model != "" do
    case provider_key(user, key_id) do
      nil ->
        {:error, "candidate provider_key_id #{key_id} is not one of your provider keys"}

      key ->
        {:ok,
         %{
           "provider_key_id" => key.id,
           "provider" => Registry.adapter_provider(key.provider_slug),
           "model" => model
         }}
    end
  end

  defp candidate_target(_user, entry),
    do: {:error, "each candidate needs provider_key_id and model, got: #{inspect(entry)}"}

  defp provider_key(user, id) do
    case uuid(id) do
      {:ok, uuid} -> Providers.get_provider_key(user, uuid)
      :error -> nil
    end
  end

  defp maybe_run(_user, _evaluation, false), do: :ok
  defp maybe_run(user, evaluation, true), do: Evaluations.enqueue(user, evaluation)

  ## Serialization

  defp model_entry(model) do
    %{
      id: model[:id],
      display_name: model[:display_name],
      input_price_per_million: money(model[:input_price]),
      output_price_per_million: money(model[:output_price]),
      max_input_tokens: model[:max_input_tokens]
    }
  end

  defp listing(evaluation) do
    %{
      id: evaluation.id,
      name: evaluation.name,
      status: evaluation.benchmark_status,
      repetitions: evaluation.repetitions,
      candidates: Enum.map(evaluation.candidate_targets, &Map.take(&1, ~w(provider model))),
      run_count: evaluation.run_count,
      request_log_id: evaluation.request_log_id,
      created_at: evaluation.inserted_at
    }
  end

  defp show_payload(conn, user, id) do
    evaluation = Evaluations.get_evaluation!(user, id)
    runs = Evaluations.latest_batch_runs(evaluation)

    %{
      id: evaluation.id,
      name: evaluation.name,
      criteria: evaluation.criteria,
      good_examples: evaluation.good_examples,
      bad_examples: evaluation.bad_examples,
      repetitions: evaluation.repetitions,
      status: evaluation.benchmark_status,
      running: Evaluations.benchmark_running?(evaluation),
      judge: %{
        provider_key_id: evaluation.judge_provider_key_id,
        model: evaluation.judge_model
      },
      request_log_id: evaluation.request_log_id,
      request_id: evaluation.request_log && evaluation.request_log.request_id,
      created_at: evaluation.inserted_at,
      summary: summary_payload(evaluation),
      rankings: Enum.map(Evaluations.rankings(evaluation), &ranking_payload/1),
      rubric_feedback: Evaluations.rubric_feedback(runs),
      runs: Enum.map(runs, &run_payload(conn, &1))
    }
  end

  defp summary_payload(evaluation) do
    evaluation
    |> Evaluations.summary()
    |> Map.update!(:total_cost_usd, &money/1)
    |> Map.update!(:total_list_cost_usd, &money/1)
  end

  defp ranking_payload(ranking) do
    %{
      provider: ranking.provider,
      model: ranking.model,
      runs: ranking.total,
      scored: ranking.successful,
      avg_score: ranking.average,
      min_score: ranking.min,
      max_score: ranking.max,
      score_stddev: ranking.stddev,
      avg_latency_ms: ranking.avg_latency,
      avg_cost_usd: money(ranking.avg_cost)
    }
  end

  # A candidate's answer is generated from the product's own prompt, so it is
  # traffic text like any other and rides the same scope as a stored body.
  defp run_payload(conn, run) do
    %{
      id: run.id,
      status: run.status,
      provider: run.candidate_provider,
      model: run.candidate_model,
      repetition: run.repetition,
      score: run.score,
      max_score: run.max_score,
      criterion_scores: run.criterion_scores,
      summary: run.summary,
      issues: run.issues,
      rubric_gaps: run.rubric_gaps,
      error: run.error,
      latency_ms: run.candidate_latency_ms,
      cost_usd: money(run.candidate_cost_usd),
      list_cost_usd: money(run.candidate_list_cost_usd),
      judge_cost_usd: money(run.judge_cost_usd),
      output_preview: body_or_marker(conn, truncate(run.candidate_output, @output_preview)),
      candidate_log_id: run.candidate_log_id,
      judge_log_id: run.judge_log_id
    }
  end

  defp error_type(404), do: "not_found"
  defp error_type(_status), do: "invalid_request_error"

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
