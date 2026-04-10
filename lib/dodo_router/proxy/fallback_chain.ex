defmodule DodoRouter.Proxy.FallbackChain do
  @moduledoc """
  Executes routing steps with fallback logic.

  Iterates through steps in order. If a step fails with a fallback-eligible error,
  moves to the next step. Records all attempts for logging.
  """

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.{Zai, Moonshot}
  alias DodoRouter.Projects.RoutingStep
  alias DodoRouter.Secrets

  defstruct [
    :request,
    :steps,
    :project_id,
    :stream,
    :send_chunk,
    attempted_steps: [],
    final_response: nil,
    status: nil
  ]

  def execute(request, steps, project_id, opts \\ []) do
    stream = Keyword.get(opts, :stream, false)
    send_chunk = Keyword.get(opts, :send_chunk, fn _ -> :ok end)

    state = %__MODULE__{
      request: request,
      steps: steps,
      project_id: project_id,
      stream: stream,
      send_chunk: send_chunk
    }

    run_chain(state)
  end

  defp run_chain(%{steps: []} = state) do
    %{state | status: :error}
  end

  defp run_chain(%{steps: [step | rest]} = state) do
    start_time = System.monotonic_time(:millisecond)
    endpoint = endpoint_for(step)

    case execute_step(step, state) do
      {:ok, response} ->
        attempt = %{
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          status: "success",
          latency_ms: latency(start_time)
        }

        status = if length(state.attempted_steps) > 0, do: :fallback, else: :success

        %{state |
          final_response: response,
          attempted_steps: state.attempted_steps ++ [attempt],
          status: status
        }

      {:error, reason, details} ->
        attempt = %{
          provider: step.provider,
          model: step.model,
          endpoint: endpoint,
          plan_type: step.plan_type,
          status: "error",
          error: to_string(reason),
          http_status: details[:status],
          error_body: truncate_error(details[:body]),
          latency_ms: details[:latency_ms] || latency(start_time)
        }

        state = %{state | attempted_steps: state.attempted_steps ++ [attempt]}

        if Adapter.should_fallback?(reason) and length(rest) > 0 do
          run_chain(%{state | steps: rest})
        else
          %{state | status: :error}
        end
    end
  end

  defp execute_step(%RoutingStep{} = step, state) do
    adapter = adapter_for(step.provider)
    api_key = get_api_key(step.provider, state.project_id)

    if is_nil(api_key) do
      {:error, :auth_error, %{reason: "Missing API key for #{step.provider}"}}
    else
      if state.stream do
        adapter.stream(state.request, step, api_key, state.send_chunk)
      else
        adapter.call(state.request, step, api_key)
      end
    end
  end

  defp adapter_for("zai"), do: Zai
  defp adapter_for("moonshot"), do: Moonshot

  defp get_api_key("zai", project_id), do: Secrets.zai_api_key(project_id)
  defp get_api_key("moonshot", project_id), do: Secrets.moonshot_api_key(project_id)

  defp endpoint_for(%RoutingStep{provider: "zai", plan_type: "coding"}),
    do: "https://api.z.ai/api/coding/paas/v4/chat/completions"
  defp endpoint_for(%RoutingStep{provider: "zai"}),
    do: "https://api.z.ai/api/paas/v4/chat/completions"
  defp endpoint_for(%RoutingStep{provider: "moonshot"}),
    do: "https://api.moonshot.cn/v1/chat/completions"

  defp truncate_error(nil), do: nil
  defp truncate_error(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} when byte_size(json) > 500 -> String.slice(json, 0, 500) <> "..."
      {:ok, json} -> json
      _ -> inspect(body) |> String.slice(0, 500)
    end
  end
  defp truncate_error(body), do: inspect(body) |> String.slice(0, 500)

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time
end
