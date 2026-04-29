defmodule DodoRouter.Forks do
  @moduledoc """
  Fork-and-run: take a published log, let the viewer edit its messages,
  then re-execute through the viewer's own router (and provider keys) to
  produce a brand-new log under their account.

  Reuses `DodoRouter.Proxy.dispatch/3` so all adapters, fallback logic, and
  log persistence work exactly like a real API call.
  """

  alias DodoRouter.Logs
  alias DodoRouter.Logs.{MessageNormalizer, RequestLog}
  alias DodoRouter.Proxy
  alias DodoRouter.Repo
  alias DodoRouter.Routers
  alias DodoRouter.Routers.Router
  alias DodoRouter.Accounts.User

  @doc """
  Run a fork. The viewer must own `router_id`. `edited_messages` is the
  list of normalized messages from the public viewer (each with `:role` and
  `:content` keys; tool_calls are not editable in v1).

  Returns `{:ok, new_log}` once the proxy has produced a log row for the
  freshly-issued request, or `{:error, reason}`.
  """
  def run_fork(%User{} = user, %RequestLog{} = parent_log, edited_messages, %{
        router_id: router_id
      }) do
    with %Router{} = router <- Routers.get_router(user, router_id),
         {:ok, request} <- build_request(parent_log, edited_messages),
         request_id = Ecto.UUID.generate(),
         {:ok, _response, _timing} <-
           Proxy.dispatch(router, request,
             request_id: request_id,
             parent_log_id: parent_log.id,
             session: %{
               session_id: parent_log.session_id,
               session_name: parent_log.session_name
             }
           ),
         {:ok, new_log} <- await_log(request_id) do
      {:ok, new_log}
    else
      nil -> {:error, :router_not_found}
      {:error, _} = err -> err
    end
  end

  defp build_request(%RequestLog{} = parent_log, edited_messages) do
    {_messages, params} = MessageNormalizer.parse_request_body(parent_log.request_body)

    request =
      params
      |> Map.put("messages", Enum.map(edited_messages, &serialize_message/1))
      # Forks always run synchronously through the public viewer; no streaming.
      |> Map.put("stream", false)

    {:ok, request}
  end

  defp serialize_message(%{role: role, content: content} = msg) do
    base = %{"role" => role, "content" => content}

    base
    |> maybe_put("tool_calls", msg[:tool_calls])
    |> maybe_put("tool_call_id", msg[:tool_call_id])
    |> maybe_put("name", msg[:name])
  end

  defp serialize_message(%{"role" => _} = msg), do: msg

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The proxy creates logs asynchronously via Task.start. Poll briefly for the
  # new row so we can hand it back to the LiveView. The proxy only fires this
  # task after the response is fully assembled, so it lands within tens of ms.
  defp await_log(request_id, attempts \\ 30)

  defp await_log(_request_id, 0), do: {:error, :log_not_persisted}

  defp await_log(request_id, attempts) do
    case Repo.get_by(RequestLog, request_id: request_id) do
      %RequestLog{} = log ->
        {:ok, log}

      nil ->
        Process.sleep(50)
        await_log(request_id, attempts - 1)
    end
  end

  @doc """
  Convenience for the LiveView: returns the routers a user can run a fork
  through, ordered by most recently used.
  """
  def runnable_routers(%User{} = user) do
    Routers.list_routers(user)
  end

  # Re-export so callers don't need to alias Logs themselves just to publish.
  defdelegate publish_log(user, log_id, attrs), to: Logs
  defdelegate unpublish_log(user, log_id), to: Logs
end
