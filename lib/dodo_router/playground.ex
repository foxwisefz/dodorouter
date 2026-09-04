defmodule DodoRouter.Playground do
  @moduledoc """
  A conversation thread against any configured provider key × model.

  Every turn is dispatched through the normal proxy pipeline as a single
  synthetic routing step — the same path a replay takes — so what the
  playground shows is what the proxy would really send, and every turn
  lands as a request log (`traffic_type: "playground"`) with its bodies,
  fidelity record and cost. Playground traffic is excluded from the
  router's analytics the same way evaluation traffic is.

  The thread itself lives in the LiveView; this module builds the request
  from it and reads the reply back into a shape the thread can render.
  """

  alias DodoRouter.Accounts.User
  alias DodoRouter.Logs
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Models
  alias DodoRouter.Models.Model
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Replays
  alias DodoRouter.Routers.Router

  @traffic_type "playground"

  def traffic_type, do: @traffic_type

  @doc "Targets a thread can be sent to: every configured key with its models."
  defdelegate list_targets(user), to: Replays

  @doc """
  The catalog row for a key × model, or nil when the catalog does not know
  the model — the source of the capability facts (vision, tools, reasoning,
  context window, prices) shown next to the picker.

  Plan catalogs live under the key slug (`moonshot_coding`); the metered
  catalog under the adapter provider is the fallback.
  """
  def model_facts(%ProviderKey{} = key, model_id) when is_binary(model_id) and model_id != "" do
    Models.get_model_by_id(key.provider_slug, model_id) ||
      Models.get_metered_model(Registry.adapter_provider(key.provider_slug), model_id)
  end

  def model_facts(_key, _model_id), do: nil

  @doc """
  The OpenAI-shaped request for a thread.

  A user turn with images becomes a parts array (`text` + `image_url` data
  URLs); a text-only turn stays a string, so the request reads the way an
  ordinary client would have sent it. Assistant turns that never completed
  (a provider error, a turn still streaming) are left out — the model
  should not be asked to continue from an answer nobody gave.
  """
  def build_request(turns, model, opts \\ []) when is_list(turns) do
    system_prompt = opts[:system_prompt]

    system =
      if is_binary(system_prompt) and String.trim(system_prompt) != "",
        do: [%{"role" => "system", "content" => system_prompt}],
        else: []

    %{"model" => model, "messages" => system ++ Enum.flat_map(turns, &turn_message/1)}
  end

  defp turn_message(%{role: :user, text: text, images: images}) when images in [nil, []] do
    [%{"role" => "user", "content" => text}]
  end

  defp turn_message(%{role: :user, text: text, images: images}) when is_list(images) do
    text_parts = if String.trim(text) == "", do: [], else: [%{"type" => "text", "text" => text}]

    image_parts =
      Enum.map(images, fn image ->
        %{"type" => "image_url", "image_url" => %{"url" => image.data_url}}
      end)

    [%{"role" => "user", "content" => text_parts ++ image_parts}]
  end

  defp turn_message(%{role: :assistant, status: :done, text: text}) when is_binary(text) do
    [%{"role" => "assistant", "content" => text}]
  end

  defp turn_message(_turn), do: []

  @doc """
  Sends one turn: dispatches `request` to `target` on `router` and waits
  for the answer.

  `target` is `%{provider_key_id:, model:, reasoning_effort:}`; the key must
  belong to `user`, and `router` is the user's router the log is filed
  under (load it with `Routers.get_router!/2`).

  Pass `on_delta: fun` to stream: the function receives
  `%{content: text, reasoning: text}` for each delta as the provider
  produces it, from the calling process. The returned reply carries the
  final text either way — the stream is for showing progress, the reply is
  the answer that was logged.

  Returns `{:ok, reply}` or `{:error, failure}`; both carry `:log`, the
  persisted request log (nil only when nothing was dispatched at all).
  """
  def send_turn(%User{} = user, %Router{} = router, target, request, opts \\ []) do
    %{provider_key_id: key_id, model: model} = target
    effort = blank_to_nil(target[:reasoning_effort])

    with :ok <- validate_model(model),
         {:ok, step} <- Replays.build_step(user, router.id, key_id, model, effort) do
      request_id = Ecto.UUID.generate()

      dispatch_opts =
        [
          steps: [step],
          log_mode: :sync,
          request_id: request_id,
          traffic_type: @traffic_type
        ] ++ stream_opts(opts[:on_delta])

      case Proxy.dispatch(router, request, dispatch_opts) do
        {:ok, response, meta} ->
          {:ok, reply(response, persisted(meta, request_id), step)}

        {:error, :all_providers_failed, attempts} ->
          {:error, failure(attempts, Logs.get_log_by_request_id(request_id), step)}

        {:error, reason} ->
          {:error, %{message: humanize(reason), log: nil, model: model, provider: step.provider}}
      end
    else
      {:error, reason} -> {:error, %{message: humanize(reason), log: nil, model: model}}
    end
  end

  defp stream_opts(nil), do: []

  defp stream_opts(on_delta) when is_function(on_delta, 1) do
    [stream: true, send_chunk: chunk_handler(on_delta)]
  end

  # Adapters hand the chain OpenAI-shaped SSE frames whatever the provider's
  # own wire format (the Anthropic adapter reframes unless the client speaks
  # Anthropic, which a playground turn never does). One frame may carry
  # several `data:` lines; anything that is not a decodable delta is skipped
  # rather than surfaced, because the logged reply is the authoritative text.
  defp chunk_handler(on_delta) do
    fn data when is_binary(data) ->
      data
      |> String.split("\n")
      |> Enum.each(fn line ->
        case decode_delta(line) do
          %{content: "", reasoning: ""} -> :ok
          nil -> :ok
          delta -> on_delta.(delta)
        end
      end)

      :ok
    end
  end

  defp decode_delta("data:" <> rest) do
    payload = String.trim(rest)

    with false <- payload in ["", "[DONE]"],
         {:ok, %{"choices" => [choice | _]}} <- Jason.decode(payload),
         delta when is_map(delta) <- choice["delta"] do
      %{
        content: text_or_empty(delta["content"]),
        reasoning: text_or_empty(delta["reasoning_content"] || delta["reasoning"])
      }
    else
      _other -> nil
    end
  end

  defp decode_delta(_line), do: nil

  defp text_or_empty(text) when is_binary(text), do: text
  defp text_or_empty(_other), do: ""

  # :sync logging hands the row back in the meta; the fallback lookup covers
  # a row that failed to persist its metadata but still exists.
  defp persisted(%{log: %RequestLog{} = log}, _request_id), do: log
  defp persisted(_meta, request_id), do: Logs.get_log_by_request_id(request_id)

  defp reply(response, log, step) do
    message = get_in(response, ["choices", Access.at(0), "message"]) || %{}

    %{
      text: flatten_text(message["content"]),
      reasoning: flatten_text(message["reasoning_content"] || message["reasoning"]),
      tool_calls: message["tool_calls"] || [],
      finish_reason: get_in(response, ["choices", Access.at(0), "finish_reason"]),
      # The serving model as stamped by the chain — a provider resolving an
      # alias reports what actually answered.
      model: non_blank(response["model"]) || (log && log.final_model) || step.model,
      provider: step.provider,
      log: log,
      latency_ms: log && log.latency_ms,
      ttfb_ms: log && log.ttfb_ms,
      prompt_tokens: log && log.prompt_tokens,
      completion_tokens: log && log.completion_tokens,
      cache_read_tokens: log && log.cache_read_tokens,
      cost_usd: log && log.estimated_cost_usd,
      list_cost_usd: log && log.list_cost_usd
    }
  end

  defp failure(attempts, log, step) do
    attempt = List.last(attempts) || %{}

    %{
      message: attempt_message(attempt, step),
      http_status: attempt[:http_status],
      error: attempt[:error],
      log: log,
      model: step.model,
      provider: step.provider,
      latency_ms: attempt[:latency_ms]
    }
  end

  # What the provider said, when it said anything parseable; otherwise the
  # chain's own reason. Both are on the log page in full.
  defp attempt_message(attempt, step) do
    provider = Registry.display_info(step.provider_key.provider_slug).name

    detail =
      case attempt[:error_body] do
        body when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) -> msg
            {:ok, %{"error" => msg}} when is_binary(msg) -> msg
            {:ok, %{"message" => msg}} when is_binary(msg) -> msg
            {:ok, msg} when is_binary(msg) -> msg
            _ -> String.slice(body, 0, 300)
          end

        _ ->
          nil
      end

    status = attempt[:http_status]
    reason = attempt[:error] && humanize(attempt[:error])

    cond do
      detail && status -> "#{provider} answered #{status}: #{detail}"
      detail -> "#{provider}: #{detail}"
      reason && status -> "#{provider} answered #{status} (#{reason})"
      reason -> "#{provider}: #{reason}"
      true -> "#{provider} did not answer"
    end
  end

  defp flatten_text(text) when is_binary(text), do: text

  defp flatten_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp flatten_text(_other), do: ""

  defp non_blank(value) when is_binary(value) and value != "", do: value
  defp non_blank(_value), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: {:error, :invalid_model}

  defp humanize(:invalid_model), do: "Pick a model first."
  defp humanize(:provider_key_not_found), do: "That provider key is no longer configured."
  defp humanize(:no_routing_configured), do: "Nothing to route to."

  defp humanize(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp humanize(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp humanize(reason), do: inspect(reason)

  @doc "True when the catalog knows the model and says it takes no images."
  def rejects_images?(%Model{supports_vision: false}), do: true
  def rejects_images?(_facts), do: false
end
