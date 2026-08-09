defmodule DodoRouter.Proxy.Adapters.Moonshot do
  @moduledoc """
  Adapter for Moonshot AI Kimi API.

  Supports kimi-k2.5 with thinking mode, kimi-k2 series, and moonshot-v1 series.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "moonshot",
    display_name: "Moonshot",
    key_slugs: ["moonshot", "moonshot_coding"],
    key_display_names: %{
      "moonshot" => "Moonshot",
      "moonshot_coding" => "Moonshot Coding"
    },
    endpoints: %{
      "moonshot" => "https://api.moonshot.ai/v1",
      "moonshot_coding" => "https://api.kimi.com/coding/v1"
    },
    models: ~w(kimi-k2.5 kimi-k2 moonshot-v1-8k moonshot-v1-32k moonshot-v1-128k),
    color: "amber",
    short_description: "Kimi K2 models",
    key_short_descriptions: %{
      "moonshot" => "Kimi models, pay-as-you-go platform API",
      "moonshot_coding" => "Kimi models via a Kimi Code subscription"
    }

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

  @doc """
  Upstream headers: our credentials plus the client's forwardable headers, per
  `Adapter.build_forwarded_headers/2`.
  """
  def request_headers(api_key, client_headers),
    do: Adapter.build_forwarded_headers(client_headers, proxy_headers(nil, api_key))

  # Debug helper - returns key hint or indicates nil/empty
  defp key_hint(nil), do: "nil"
  defp key_hint(""), do: "empty"

  defp key_hint(key) when byte_size(key) > 8,
    do: "#{String.slice(key, 0, 4)}...#{String.slice(key, -4, 4)}"

  defp key_hint(_), do: "short"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    url = base_url(step) <> "/chat/completions"
    body = build_request_body(request, step)

    headers =
      Adapter.build_forwarded_headers(client_headers, proxy_headers(step, api_key))

    Logger.info(
      "[Moonshot:call] url=#{url} model=#{body["model"]} plan=#{step.plan_type || "standard"} " <>
        "key_hint=#{key_hint(api_key)} auth_present=#{Enum.any?(headers, fn {k, _} -> String.downcase(k) == "authorization" end)} " <>
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

        {:ok, Map.put(response_body, "_meta", meta),
         %{headers: resp_headers, outbound_headers: headers}}

      {:ok, %{status: status, body: response_body, headers: resp_headers}} ->
        Logger.error(
          "[Moonshot] Non-200 response: status=#{status} body=#{inspect(response_body)}"
        )

        reason = Adapter.categorize_error(status, response_body)

        {:error, reason,
         %{
           status: status,
           body: response_body,
           latency_ms: latency(start_time),
           headers: resp_headers,
           outbound_headers: headers
         }}

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

    headers =
      Adapter.build_forwarded_headers(client_headers, proxy_headers(step, api_key))

    Logger.info(
      "[Moonshot:stream] url=#{url} model=#{body["model"]} plan=#{step.plan_type || "standard"} " <>
        "key_hint=#{key_hint(api_key)} auth_present=#{Enum.any?(headers, fn {k, _} -> String.downcase(k) == "authorization" end)} " <>
        "headers=#{inspect(safe_headers(headers))}"
    )

    payload_size_bytes = body |> Jason.encode!() |> byte_size()

    # Track partial content in process dict so it survives error paths
    Process.delete(:__moonshot_stream_acc__)
    Process.delete(:__moonshot_stream_raw__)
    start_time = FinchTelemetry.mark_request_start()

    into_fun = fn
      {:data, data}, {req, resp} when resp.status != 200 ->
        Adapter.capture_streamed_error({:data, data}, {req, resp})

      {:data, data}, {req, resp} ->
        raw = Process.get(:__moonshot_stream_raw__, "")
        Process.put(:__moonshot_stream_raw__, raw <> data)

        resp =
          if resp.private[:stream_acc] == nil do
            ttfb = System.monotonic_time(:millisecond) - start_time

            initial_acc = %{
              content: "",
              tool_calls: %{},
              usage: nil,
              finish_reason: nil,
              first_chunk_time: ttfb,
              sse_buffer: ""
            }

            Req.Response.put_private(resp, :stream_acc, initial_acc)
          else
            resp
          end

        acc = resp.private.stream_acc

        case Adapter.parse_sse_chunk(data, acc.sse_buffer) do
          {{:chunks, chunks}, buffer} ->
            reframe_and_send_chunks(send_chunk, chunks)
            acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
            acc = %{acc | sse_buffer: buffer}
            Process.put(:__moonshot_stream_acc__, acc)
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

          {{:chunks_then_done, chunks}, _buffer} ->
            reframe_and_send_chunks(send_chunk, chunks)
            acc = Enum.reduce(chunks, acc, &accumulate_chunk(&2, &1))
            acc = %{acc | sse_buffer: ""}
            Process.put(:__moonshot_stream_acc__, acc)
            {:halt, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

          {:done, _buffer} ->
            send_chunk.("data: [DONE]\n\n")
            {:halt, {req, resp}}

          {:skip, buffer} ->
            acc = %{acc | sse_buffer: buffer}
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}
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
    raw_error = Process.get(:__moonshot_stream_raw__)
    Process.delete(:__moonshot_stream_acc__)
    Process.delete(:__moonshot_stream_raw__)

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

        {:ok, build_final_response(acc, timing_meta),
         %{headers: resp_headers, outbound_headers: headers}}

      {:ok, %Req.Response{status: status, headers: resp_headers} = resp} ->
        body = Adapter.streamed_error_body(resp)
        error_body = if body in ["", nil], do: parse_raw_error(raw_error), else: body
        Logger.error("[Moonshot] Stream error: status=#{status} body=#{inspect(error_body)}")

        reason = Adapter.categorize_error(status, error_body)

        {:error, reason,
         %{
           status: status,
           body: error_body,
           latency_ms: latency(start_time),
           headers: resp_headers,
           outbound_headers: headers
         }}

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
      |> normalize_temperature(step)
      |> handle_tool_choice_required()
      |> normalize_tool_call_arguments()
      |> sanitize_tool_names()
      |> maybe_put_thinking(step)
      |> maybe_transform_kimi_reasoning(step)

    assistant_debug =
      (body["messages"] || [])
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _i} -> msg["role"] == "assistant" end)
      |> Enum.map(fn {msg, i} ->
        has_tc = Map.has_key?(msg, "tool_calls")
        has_rc = Map.has_key?(msg, "reasoning_content")
        "[#{i}: tc=#{has_tc} rc=#{has_rc}]"
      end)
      |> Enum.join(", ")

    Logger.info(
      "[Moonshot] Sending request model=#{body["model"]} msg_count=#{length(body["messages"] || [])} thinking=#{inspect(body["thinking"])} assistants=[#{assistant_debug}]"
    )

    body
  end

  # Only set default if client didn't provide a value
  defp maybe_default(map, _key, nil), do: map

  defp maybe_default(map, key, default) do
    if Map.has_key?(map, key), do: map, else: Map.put(map, key, default)
  end

  # Kimi K2.5+ (kimi-k2.5, kimi-k2.6, kimi-k2.7-code, ...) and the coding-plan
  # kimi-for-coding model pin temperature server-side and reject any explicit
  # value with "invalid temperature: only X is allowed for this model" — the
  # docs say to omit the parameter entirely, so we strip it (including step
  # defaults) rather than clamp.
  defp fixed_temperature_model?(model) when is_binary(model),
    do: String.starts_with?(model, "kimi-k2.") or model == "kimi-for-coding"

  defp fixed_temperature_model?(_), do: false

  defp normalize_temperature(body, %RoutingStep{model: model}) do
    if fixed_temperature_model?(model),
      do: Map.delete(body, "temperature"),
      else: clamp_temperature(body)
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

  defp normalize_tool_call_arguments(%{"messages" => messages} = body) when is_list(messages) do
    updated =
      Enum.map(messages, fn
        %{"tool_calls" => tool_calls} = msg when is_list(tool_calls) ->
          normalized =
            Enum.map(tool_calls, fn tc ->
              case get_in(tc, ["function", "arguments"]) do
                args when is_map(args) ->
                  put_in(tc, ["function", "arguments"], Jason.encode!(args))

                _ ->
                  tc
              end
            end)

          Map.put(msg, "tool_calls", normalized)

        msg ->
          msg
      end)

    Map.put(body, "messages", updated)
  end

  defp normalize_tool_call_arguments(body), do: body

  # Moonshot only supports function-type tools. Filter out web_search,
  # image_generation, and other non-function tool types.
  defp sanitize_tool_names(%{"tools" => tools} = body) when is_list(tools) do
    sanitized =
      Enum.filter(tools, fn
        %{"type" => "function"} -> true
        _ -> false
      end)

    if sanitized == [] do
      Map.delete(body, "tools")
    else
      Map.put(body, "tools", sanitized)
    end
  end

  defp sanitize_tool_names(body), do: body

  defguardp is_kimi_thinking_model(model)
            when is_binary(model) and
                   (binary_part(model, 0, 7) == "kimi-k2" or model == "kimi-for-coding")

  # Effective thinking state for a kimi model, resolving the new
  # `reasoning_effort` field first and falling back to the legacy
  # `thinking_enabled` boolean for rows created before the migration.
  defp kimi_thinking_on?(%RoutingStep{reasoning_effort: effort})
       when is_binary(effort) and effort != "" and effort != "none",
       do: true

  defp kimi_thinking_on?(%RoutingStep{reasoning_effort: effort})
       when is_binary(effort) and effort == "none",
       do: false

  defp kimi_thinking_on?(%RoutingStep{thinking_enabled: false}), do: false
  defp kimi_thinking_on?(_step), do: true

  # kimi thinking models have thinking enabled by default - only disable if
  # explicitly turned off (via reasoning_effort="none" or thinking_enabled=false).
  defp maybe_put_thinking(body, %RoutingStep{model: model} = step)
       when is_kimi_thinking_model(model) do
    if kimi_thinking_on?(step),
      do: Map.put(body, "thinking", %{"type" => "enabled"}),
      else: Map.put(body, "thinking", %{"type" => "disabled"})
  end

  defp maybe_put_thinking(body, _step), do: body

  defp maybe_transform_kimi_reasoning(body, %RoutingStep{model: model} = step)
       when is_binary(model) do
    is_kimi_k2 = String.starts_with?(model, "kimi-k2") or model == "kimi-for-coding"

    if is_kimi_k2 and kimi_thinking_on?(step) do
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

  # Moonshot requires reasoning_content on assistant messages that have tool_calls.
  # Use " " (space) as minimum placeholder — empty string "" is rejected by the API.
  defp ensure_reasoning_content(%{"reasoning_content" => rc} = msg)
       when is_binary(rc) and rc != "", do: msg

  defp ensure_reasoning_content(%{"tool_calls" => _} = msg),
    do: Map.put(msg, "reasoning_content", " ")

  defp ensure_reasoning_content(msg), do: msg

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

  @doc false
  def parse_raw_error(nil), do: nil

  @doc false
  def parse_raw_error(data) when is_binary(data) do
    data = maybe_gunzip(data)

    case Adapter.parse_sse_chunk(data, "") do
      {{:chunks, chunks}, _buffer} ->
        text =
          chunks
          |> Enum.map(fn c -> get_in(c, ["choices", Access.at(0), "delta", "content"]) || "" end)
          |> Enum.join()

        if text != "", do: text, else: nil

      _ ->
        case Jason.decode(data) do
          {:ok, decoded} -> decoded
          _ -> data
        end
    end
  end

  defp maybe_gunzip(<<31, 139, 8, _::binary>> = data) do
    case :zlib.gunzip(data) do
      decompressed when is_binary(decompressed) -> decompressed
      _ -> data
    end
  end

  defp maybe_gunzip(data), do: data

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
