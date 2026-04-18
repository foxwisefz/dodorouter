defmodule DodoRouter.Proxy.Adapters.Moonshot do
  @moduledoc """
  Adapter for Moonshot AI Kimi API.

  Supports kimi-k2.5 with thinking mode, kimi-k2 series, and moonshot-v1 series.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "moonshot",
    display_name: "Moonshot (Kimi)",
    key_slugs: ["moonshot", "moonshot_coding"],
    endpoints: %{
      "moonshot" => "https://api.moonshot.ai/v1",
      "moonshot_coding" => "https://api.kimi.com/coding/v1"
    },
    models: ~w(kimi-k2.5 kimi-k2 moonshot-v1-8k moonshot-v1-32k moonshot-v1-128k),
    color: "amber",
    short_description: "Kimi K2 models"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @standard_base_url "https://api.moonshot.ai/v1"
  @coding_base_url "https://api.kimi.com/coding/v1"
  @timeout_ms 120_000

  @doc false
  def base_url(%RoutingStep{plan_type: "coding"}), do: @coding_base_url
  def base_url(_), do: @standard_base_url

  defp proxy_headers(_step, api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    url = base_url(step) <> "/chat/completions"
    body = build_request_body(request, step)

    headers =
      Adapter.build_forwarded_headers(client_headers, proxy_headers(step, api_key))

    Logger.info(
      "[Moonshot:call] url=#{url} model=#{body["model"]} plan=#{step.plan_type || "standard"} " <>
        "headers=#{inspect(safe_headers(headers))}"
    )

    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body, headers: resp_headers}} ->
        total_ms = latency(start_time)
        upload_ms = FinchTelemetry.get_upload_ms(start_time)

        meta = %{
          "ttfb_ms" => total_ms,
          "upload_ms" => upload_ms,
          "payload_size_bytes" => payload_size_bytes,
          "provider_processing_ms" => nil
        }

        {:ok, Map.put(response_body, "_meta", meta), %{headers: resp_headers}}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("[Moonshot] Non-200 response: status=#{status}")

        reason = Adapter.categorize_error(status, response_body)
        {:error, reason, %{status: status, body: response_body, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    url = base_url(step) <> "/chat/completions"

    body =
      build_request_body(request, step)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    headers =
      Adapter.build_forwarded_headers(client_headers, proxy_headers(step, api_key))

    Logger.info(
      "[Moonshot:stream] url=#{url} model=#{body["model"]} plan=#{step.plan_type || "standard"} " <>
        "headers=#{inspect(safe_headers(headers))}"
    )

    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()

    # Track partial content in process dict so it survives error paths
    Process.delete(:__moonshot_stream_acc__)

    into_fun = fn {:data, data}, {req, resp} ->
      resp =
        if resp.private[:stream_acc] == nil do
          ttfb = System.monotonic_time(:millisecond) - start_time

          initial_acc = %{
            content: "",
            tool_calls: %{},
            usage: nil,
            finish_reason: nil,
            first_chunk_time: ttfb
          }

          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case Adapter.parse_sse_chunk(data) do
        {:chunks, chunks} ->
          reframe_and_send_chunks(send_chunk, chunks)
          acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
          Process.put(:__moonshot_stream_acc__, acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        {:chunks_then_done, chunks} ->
          reframe_and_send_chunks(send_chunk, chunks)
          acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
          Process.put(:__moonshot_stream_acc__, acc)
          {:halt, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

        :done ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        :skip ->
          {:cont, {req, resp}}
      end
    end

    result =
      Req.post(url,
        headers: headers,
        json: body,
        receive_timeout: @timeout_ms,
        into: into_fun
      )

    partial_acc = Process.get(:__moonshot_stream_acc__)
    Process.delete(:__moonshot_stream_acc__)

    case result do
      {:ok, %Req.Response{status: 200, headers: resp_headers} = resp} ->
        acc =
          resp.private[:stream_acc] || partial_acc ||
            %{content: "", tool_calls: %{}, usage: nil, finish_reason: nil, first_chunk_time: nil}

        upload_ms = calculate_upload_ms(start_time)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: nil
        }

        {:ok, build_final_response(acc, timing_meta), %{headers: resp_headers}}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("[Moonshot] Stream error: status=#{status}")

        reason = Adapter.categorize_error(status, %{"error" => "stream error"})
        {:error, reason, %{status: status, latency_ms: latency(start_time)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, build_stream_error_details(partial_acc, start_time)}

      {:error, reason} ->
        {:error, :unknown, build_stream_error_details(partial_acc, start_time, %{reason: reason})}
    end
  end

  @doc false
  def build_request_body(request, %RoutingStep{} = step) do
    # Model always comes from routing step
    # Client values take precedence, step defaults are fallbacks
    body =
      request
      |> Adapter.sanitize_request()
      |> Adapter.flatten_content_to_string()
      |> Map.put("model", step.model)
      |> maybe_default("temperature", step.temperature)
      |> maybe_default("max_tokens", step.max_tokens)
      |> maybe_default("top_p", nil)
      |> maybe_default("frequency_penalty", nil)
      |> maybe_default("presence_penalty", nil)
      |> maybe_default("stop", nil)
      |> clamp_temperature()
      |> handle_tool_choice_required()
      |> maybe_put_thinking(step)
      |> maybe_transform_kimi_reasoning(step)

    Logger.info(
      "[Moonshot] Sending request model=#{body["model"]} msg_count=#{length(body["messages"] || [])}"
    )

    body
  end

  # Only set default if client didn't provide a value
  defp maybe_default(map, _key, nil), do: map

  defp maybe_default(map, key, default) do
    if Map.has_key?(map, key), do: map, else: Map.put(map, key, default)
  end

  # Moonshot temperature range is [0, 1], OpenAI is [0, 2]
  # Also: if temp < 0.3 and n > 1, Moonshot raises an exception
  defp clamp_temperature(body) do
    case body["temperature"] do
      nil ->
        body

      temp when is_number(temp) ->
        n = body["n"] || 1
        clamped = temp |> max(0.0) |> min(1.0)

        # Bump to 0.3 if n > 1 and temp < 0.3
        clamped = if clamped < 0.3 and n > 1, do: 0.3, else: clamped

        Map.put(body, "temperature", clamped)

      _ ->
        body
    end
  end

  # Moonshot doesn't support tool_choice="required"
  # Workaround: add a user message asking to select a tool
  defp handle_tool_choice_required(%{"tool_choice" => "required"} = body) do
    messages = body["messages"] || []

    messages =
      messages ++
        [
          %{
            "role" => "user",
            "content" => "Please select a tool to handle the current issue."
          }
        ]

    body
    |> Map.put("messages", messages)
    |> Map.delete("tool_choice")
  end

  defp handle_tool_choice_required(body), do: body

  defguardp is_kimi_thinking_model(model)
            when is_binary(model) and
                   (binary_part(model, 0, 7) == "kimi-k2" or model == "kimi-for-coding")

  # kimi thinking models have thinking enabled by default - only disable if explicitly false
  defp maybe_put_thinking(body, %RoutingStep{model: model, thinking_enabled: false})
       when is_kimi_thinking_model(model) do
    Map.put(body, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(body, %RoutingStep{model: model, thinking_enabled: thinking})
       when is_kimi_thinking_model(model) and thinking != false do
    Map.put(body, "thinking", %{"type" => "enabled"})
  end

  defp maybe_put_thinking(body, _step), do: body

  defp maybe_transform_kimi_reasoning(body, %RoutingStep{model: model, thinking_enabled: thinking})
       when is_binary(model) do
    is_kimi_k2 = String.starts_with?(model, "kimi-k2") or model == "kimi-for-coding"

    if is_kimi_k2 and thinking != false do
      messages =
        Enum.map(body["messages"] || [], fn msg ->
          case msg["role"] do
            "assistant" ->
              msg
              |> convert_reasoning_details()
              |> ensure_reasoning_content()

            _ ->
              msg
          end
        end)

      Map.put(body, "messages", messages)
    else
      body
    end
  end

  defp maybe_transform_kimi_reasoning(body, _step), do: body

  # Convert reasoning_details array → reasoning_content flat string
  defp convert_reasoning_details(%{"reasoning_details" => details} = msg) when is_list(details) do
    reasoning_content =
      details
      |> Enum.filter(fn
        %{"type" => "reasoning.text"} -> true
        _ -> false
      end)
      |> Enum.map(fn %{"text" => text} -> text end)
      |> Enum.join("")

    msg
    |> Map.put("reasoning_content", reasoning_content)
    |> Map.delete("reasoning_details")
  end

  defp convert_reasoning_details(msg), do: msg

  # kimi-k2.5 has thinking enabled by default, so ALL assistant messages
  # need reasoning_content, not just ones with tool_calls.
  defp ensure_reasoning_content(msg) do
    Map.put_new(msg, "reasoning_content", "")
  end

  defp accumulate_chunk(acc, chunk_data) do
    choice = get_in(chunk_data, ["choices", Access.at(0)])

    content =
      case get_in(choice, ["delta", "content"]) do
        nil -> acc.content
        c -> acc.content <> c
      end

    reasoning_content =
      case get_in(choice, ["delta", "reasoning_content"]) do
        nil -> Map.get(acc, :reasoning_content, "")
        rc -> Map.get(acc, :reasoning_content, "") <> rc
      end

    tool_calls = accumulate_tool_calls(acc.tool_calls, chunk_data)
    usage = chunk_data["usage"] || acc.usage

    finish_reason = get_in(choice, ["finish_reason"]) || acc.finish_reason

    %{acc | content: content, tool_calls: tool_calls, usage: usage, finish_reason: finish_reason}
    |> Map.put(:reasoning_content, reasoning_content)
  end

  @doc false
  def accumulate_tool_calls(existing, chunk_data) do
    case get_in(chunk_data, ["choices", Access.at(0), "delta", "tool_calls"]) do
      nil ->
        existing

      calls when is_list(calls) ->
        Enum.reduce(calls, existing, fn call, acc ->
          index = call["index"] || 0

          case Map.get(acc, index) do
            nil ->
              # First chunk for this tool call - initialize it
              Map.put(acc, index, %{
                "id" => call["id"],
                "type" => call["type"] || "function",
                "function" => %{
                  "name" => get_in(call, ["function", "name"]) || "",
                  "arguments" => get_in(call, ["function", "arguments"]) || ""
                }
              })

            existing_call ->
              # Subsequent chunk - append arguments
              new_args =
                existing_call["function"]["arguments"] <>
                  (get_in(call, ["function", "arguments"]) || "")

              new_name =
                case get_in(call, ["function", "name"]) do
                  nil -> existing_call["function"]["name"]
                  name -> name
                end

              put_in(
                acc,
                [index, "function"],
                %{"name" => new_name, "arguments" => new_args}
              )
          end
        end)
    end
  end

  defp build_final_response(acc, timing_meta) do
    message = build_final_message(acc)

    meta = %{
      "ttfb_ms" => acc.first_chunk_time,
      "upload_ms" => timing_meta.upload_ms,
      "payload_size_bytes" => timing_meta.payload_size_bytes,
      "provider_processing_ms" => timing_meta.provider_processing_ms
    }

    %{
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => acc.finish_reason
        }
      ],
      "usage" => acc.usage,
      "_meta" => meta
    }
  end

  defp build_final_message(acc) do
    base = %{"role" => "assistant", "content" => acc.content}

    base =
      case Map.get(acc, :reasoning_content) do
        nil -> base
        "" -> base
        rc -> Map.put(base, "reasoning_content", rc)
      end

    if map_size(acc.tool_calls) > 0 do
      tool_calls_list =
        acc.tool_calls
        |> Enum.sort_by(fn {index, _} -> index end)
        |> Enum.map(fn {_index, call} -> call end)

      Map.put(base, "tool_calls", tool_calls_list)
    else
      base
    end
  end

  defp build_stream_error_details(partial_acc, start_time, extra \\ %{})

  defp build_stream_error_details(nil, start_time, extra) do
    Map.merge(%{latency_ms: latency(start_time)}, extra)
  end

  defp build_stream_error_details(partial_acc, start_time, extra) do
    Map.merge(
      %{
        latency_ms: latency(start_time),
        partial_content: partial_acc.content,
        chunks_sent: partial_acc.content != ""
      },
      extra
    )
  end

  defp reframe_and_send_chunks(send_chunk, chunks) do
    Enum.each(chunks, fn chunk_data ->
      event = "data: " <> Jason.encode!(chunk_data) <> "\n\n"
      send_chunk.(event)
    end)
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp safe_headers(headers) do
    Enum.map(headers, fn
      {"Authorization", "Bearer " <> _rest} = h ->
        put_elem(h, 1, "Bearer sk-***")

      {"Authorization", _} ->
        {"Authorization", "***"}

      other ->
        other
    end)
  end

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
