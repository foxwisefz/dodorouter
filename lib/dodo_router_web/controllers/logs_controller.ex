defmodule DodoRouterWeb.LogsController do
  @moduledoc """
  Read-only access to a router's request logs for agents.

  This is the entry point of the evaluation loop: an agent can only evaluate
  a request the product actually made, so it has to be able to find one first.
  Each row carries whether it can be replayed, because an evaluation built on
  a log that can't be is a benchmark that fails minutes later for a reason the
  agent could have been told up front.
  """

  use DodoRouterWeb, :controller

  import DodoRouterWeb.AgentApi

  alias DodoRouter.{Logs, Replays}

  def index(conn, params) do
    router = conn.assigns.current_router
    {limit, offset} = paging(params)

    opts = [
      limit: limit,
      offset: offset,
      status: presence(params["status"]),
      provider: presence(params["provider"]),
      model: presence(params["model"]),
      call_type: presence(params["call_type"]),
      favorites_only: params["favorites_only"] in [true, "true", "1"]
    ]

    logs = Logs.list_logs(router, opts)

    # `returned`, never `count`: this is the size of this page, and a field
    # called count reads as a total the query never asked for.
    json(conn, %{
      data: Enum.map(logs, &summary/1),
      limit: limit,
      offset: offset,
      returned: length(logs)
    })
  end

  def show(conn, %{"id" => id}) do
    user = current_user(conn)
    router = conn.assigns.current_router

    case fetch_log(user, id) do
      %{router_id: router_id} = log when router_id == router.id ->
        json(conn, detail(log))

      _ ->
        error(conn, 404, "No log #{id} on router #{router.slug}", "not_found")
    end
  end

  # An agent holds the `request_id` it saw on its own proxy response far more
  # often than the internal log id, and both are UUIDs — so neither can be
  # told from the other by shape. Try the primary key, then the request id.
  defp fetch_log(user, id) do
    with {:ok, uuid} <- uuid(id) do
      Logs.get_log(user, uuid) || Logs.get_log_by_request_id(user, uuid)
    else
      :error -> nil
    end
  end

  defp summary(log) do
    blocker = Replays.replay_blocker(log)

    %{
      id: log.id,
      request_id: log.request_id,
      status: log.status,
      http_status: log.http_status,
      provider: log.final_provider,
      model: log.final_model,
      call_type: log.call_type,
      tools_invoked: log.tools_invoked,
      prompt_tokens: log.prompt_tokens,
      completion_tokens: log.completion_tokens,
      total_tokens: log.total_tokens,
      cache_read_tokens: log.cache_read_tokens,
      cache_write_tokens: log.cache_write_tokens,
      latency_ms: log.latency_ms,
      ttfb_ms: log.ttfb_ms,
      cost_usd: money(log.estimated_cost_usd),
      list_cost_usd: money(log.list_cost_usd),
      session_id: log.session_id,
      created_at: log.inserted_at,
      evaluable: is_nil(blocker),
      not_evaluable_because: blocker_reason(blocker)
    }
  end

  defp detail(log) do
    log
    |> summary()
    |> Map.merge(%{
      request_body: maybe_json(log.request_body),
      response_body: maybe_json(log.response_body),
      truncation_flags: log.truncation_flags,
      replayed_from_id: log.replayed_from_id,
      traffic_type: log.traffic_type
    })
  end

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value
end
