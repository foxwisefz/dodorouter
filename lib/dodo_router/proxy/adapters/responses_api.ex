defmodule DodoRouter.Proxy.Adapters.ResponsesAPI do
  @moduledoc """
  Shared implementation for providers that use the OpenAI Responses API format
  on the upstream side (proxy -> provider).

  The Responses API uses `input` instead of `messages`, requires `stream: true`
  and `store: false`, and emits different SSE event types than Chat Completions.

  This module converts between OpenAI Chat Completions format (used internally
  by the proxy) and the Responses API format in both directions.

  Providers like OpenAI Codex (ChatGPT backend) use this format.  Future
  providers that expose a Responses API endpoint can delegate here the same
  way Groq, Mistral, etc. delegate to `OpenAICompatible`.
  """

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Routers.RoutingStep

  @doc """
  Synchronous call.  The Responses API always requires streaming, so this
  internally streams and accumulates the full response.
  """
  def call(request, %RoutingStep{} = step, api_key, endpoint, opts \\ []) do
    stream(request, step, api_key, fn _data -> :ok end, endpoint, opts)
  end

  @doc """
  Streaming call.  Converts the request to Responses API format, streams the
  response, and converts Responses API SSE events back to OpenAI chat
  completions chunks in real time.
  """
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, endpoint, opts \\ []) do
    provider = Keyword.get(opts, :provider, "responses-api")

    body =
      build_request_body(request, step)
      |> Map.put("stream", true)

    headers = build_headers(api_key, opts)
    payload_size_bytes = Adapter.record_outbound_body(body)
    start_time = System.monotonic_time(:millisecond)

    into_fun = fn
      {:data, data}, {req, resp} when resp.status != 200 ->
        Adapter.capture_streamed_error({:data, data}, {req, resp})

      {:data, data}, {req, resp} ->
        resp =
          if resp.private[:stream_acc] == nil do
            ttfb = System.monotonic_time(:millisecond) - start_time

            initial_acc = %{
              model: step.model,
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

        sacc = resp.private.stream_acc
        combined = sacc.sse_buffer <> data

        case parse_sse_events(combined) do
          {:events, events, buffer} ->
            {sacc, openai_chunks} = process_events(sacc, events)

            Enum.each(openai_chunks, &send_chunk.(&1))

            sacc = %{sacc | sse_buffer: buffer}
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, sacc)}}

          {:incomplete, buffer} ->
            sacc = %{sacc | sse_buffer: buffer}
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, sacc)}}
        end
    end

    result =
      Req.post(endpoint,
        headers: headers,
        json: body,
        receive_timeout: Adapter.receive_timeout(),
        into: into_fun
      )

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc =
          resp.private[:stream_acc] ||
            %{
              model: step.model,
              content: "",
              tool_calls: %{},
              usage: nil,
              finish_reason: nil,
              first_chunk_time: nil
            }

        send_chunk.("data: [DONE]\n\n")

        meta = %{
          "ttfb_ms" => acc.first_chunk_time,
          "upload_ms" => nil,
          "payload_size_bytes" => payload_size_bytes,
          "provider_processing_ms" => nil
        }

        {:ok, build_final_response(acc, meta),
         %{headers: resp.headers, outbound_headers: headers, outbound_body: body}}

      {:ok, %Req.Response{status: status, headers: resp_headers} = resp} ->
        resp_body = Adapter.streamed_error_body(resp)
        Logger.error("[#{provider}] Non-200: status=#{status} body=#{inspect(resp_body)}")
        reason = Adapter.categorize_error(status, resp_body)

        {:error, reason,
         %{
           status: status,
           body: resp_body,
           latency_ms: latency(start_time),
           headers: resp_headers,
           outbound_headers: headers,
           outbound_body: body
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  # ── Request conversion: OpenAI chat completions -> Responses API ─────────--

  @doc false
  def build_request_body(request, step) do
    input = convert_messages_to_input(request["messages"] || [])

    %{}
    |> Map.put("model", step.model)
    |> Map.put("input", input)
    |> Map.put("store", false)
    |> maybe_put("temperature", request["temperature"])
    |> maybe_put("top_p", request["top_p"])
    |> maybe_put_tools(request["tools"])
    |> put_reasoning(request)
    |> Adapter.inject_reasoning_effort(step.reasoning_effort, :responses)
    |> restore_client_passthrough(request)
  end

  # A Responses-format request served by a Responses-format adapter never
  # needed translating, so the fields the IR could not carry — `text`
  # (structured outputs), `previous_response_id`, and whatever OpenAI ships
  # next — go back on the wire as the client sent them. `FallbackChain` only
  # attaches them when the formats match; a fallback to anything else reports
  # them as lost against that step instead.
  #
  # The body wins every collision, and the passthrough is built from the keys
  # the converter did *not* consume, so it cannot carry a stale `model` or
  # `tools` back over a routing decision.
  defp restore_client_passthrough(body, request) do
    case Adapter.client_passthrough(request) do
      fields when map_size(fields) == 0 -> body
      fields -> Map.merge(fields, body)
    end
  end

  defp put_reasoning(body, %{} = request) do
    cond do
      is_map(request["reasoning"]) ->
        Map.put(body, "reasoning", request["reasoning"])

      request["reasoning_effort"] in [nil, "", "none"] ->
        body

      is_binary(request["reasoning_effort"]) ->
        Map.put(body, "reasoning", %{"effort" => request["reasoning_effort"]})

      true ->
        body
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, nil), do: map

  defp maybe_put_tools(map, tools) when is_list(tools) do
    converted =
      Enum.map(tools, fn tool ->
        case tool do
          %{"function" => func} ->
            %{
              "type" => "function",
              "name" => func["name"],
              "description" => func["description"] || "",
              "parameters" => func["parameters"] || %{"type" => "object", "properties" => %{}}
            }

          other ->
            other
        end
      end)

    Map.put(map, "tools", converted)
  end

  defp convert_messages_to_input(messages) do
    Enum.flat_map(messages, &convert_message/1)
  end

  # Typed non-message Responses items are already in the upstream format.
  # Looking at role first turns additional_tools into a null developer message;
  # requiring a role also crashes on reasoning and function-call history.
  defp convert_message(%{"type" => type} = item) when is_binary(type) and type != "message",
    do: [item]

  defp convert_message(%{"role" => "system", "content" => content}) when is_list(content) do
    [%{"role" => "system", "content" => convert_input_parts(content)}]
  end

  defp convert_message(%{"role" => "system", "content" => content}) do
    [%{"role" => "system", "content" => content}]
  end

  defp convert_message(%{"role" => "user", "content" => content}) when is_binary(content) do
    [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => content}]}]
  end

  defp convert_message(%{"role" => "user", "content" => content}) when is_list(content) do
    [%{"role" => "user", "content" => convert_input_parts(content)}]
  end

  defp convert_message(%{"role" => "assistant"} = msg) do
    items = []

    items =
      if msg["content"] not in [nil, ""] do
        items ++
          [
            %{
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => msg["content"]}]
            }
          ]
      else
        items
      end

    items =
      case msg["tool_calls"] do
        nil ->
          items

        tool_calls ->
          items ++
            Enum.map(tool_calls, fn tc ->
              %{
                "type" => "function_call",
                "call_id" => tc["id"],
                "name" => get_in(tc, ["function", "name"]),
                "arguments" => get_in(tc, ["function", "arguments"]) || "{}"
              }
            end)
      end

    items
  end

  defp convert_message(%{"role" => "tool", "tool_call_id" => call_id, "content" => content}) do
    [%{"type" => "function_call_output", "call_id" => call_id, "output" => content}]
  end

  defp convert_message(%{"role" => _} = msg) do
    [%{"role" => msg["role"], "content" => msg["content"]}]
  end

  # Multi-block content arrives as Anthropic-style text parts (the ingress
  # keeps them as arrays so cache_control breakpoints survive on Anthropic
  # steps). Input to the Responses API names the type input_text, and the
  # cache_control key must not travel — Responses providers reject unknown
  # fields on content parts.
  defp convert_input_parts(content) do
    Enum.map(content, fn part ->
      case part["type"] do
        "text" ->
          %{"type" => "input_text", "text" => part["text"]}

        "image_url" ->
          image = part["image_url"] || %{}

          %{"type" => "input_image", "image_url" => image["url"]}
          |> maybe_put("detail", image["detail"])

        _ ->
          part
      end
    end)
  end

  # ── SSE parsing ────────────────────────────────────────────────────────────

  defp parse_sse_events(data) do
    lines = String.split(data, "\n")

    {complete, incomplete} =
      case List.last(lines) do
        "" -> {Enum.drop(lines, -1), ""}
        nil -> {lines, ""}
        last -> {Enum.drop(lines, -1), last}
      end

    events =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if events == [] do
      {:incomplete, incomplete}
    else
      {:events, events, incomplete}
    end
  end

  # ── Response conversion: Responses API events -> OpenAI chat chunks ────────

  @doc false
  def process_events(acc, events) do
    Enum.reduce(events, {acc, []}, fn event, {sacc, chunks} ->
      case event["type"] do
        "response.output_text.delta" ->
          delta = event["delta"]
          new_acc = %{sacc | content: sacc.content <> delta}
          chunk = build_openai_chunk(%{"content" => delta})
          {new_acc, chunks ++ [chunk]}

        "response.output_item.added" ->
          item = event["item"]

          case item["type"] do
            "function_call" ->
              call_id = item["call_id"]
              name = item["name"]
              idx = map_size(sacc.tool_calls)

              entry = %{
                "id" => call_id,
                "type" => "function",
                "function" => %{"name" => name, "arguments" => ""},
                item_id: item["id"] || call_id
              }

              new_acc = put_in(sacc.tool_calls[idx], entry)

              chunk =
                build_openai_chunk(%{
                  "tool_calls" => [
                    %{
                      "index" => idx,
                      "id" => call_id,
                      "type" => "function",
                      "function" => %{"name" => name}
                    }
                  ]
                })

              {new_acc, chunks ++ [chunk]}

            _ ->
              {sacc, chunks}
          end

        "response.function_call_arguments.delta" ->
          event_id = event["item_id"] || event["call_id"]
          args_delta = event["delta"]

          {idx, entry} =
            Enum.find(sacc.tool_calls, fn {_i, e} ->
              e[:item_id] == event_id or e["id"] == event_id
            end) ||
              {map_size(sacc.tool_calls), nil}

          if entry do
            updated_fn = %{
              entry["function"]
              | "arguments" => entry["function"]["arguments"] <> args_delta
            }

            new_acc =
              put_in(sacc.tool_calls[idx], %{
                entry
                | "function" => updated_fn
              })

            chunk =
              build_openai_chunk(%{
                "tool_calls" => [
                  %{
                    "index" => idx,
                    "function" => %{"arguments" => args_delta}
                  }
                ]
              })

            {new_acc, chunks ++ [chunk]}
          else
            {sacc, chunks}
          end

        "response.completed" ->
          usage = get_in(event, ["response", "usage"])
          finish_reason = if map_size(sacc.tool_calls) > 0, do: "tool_calls", else: "stop"

          new_acc =
            if usage do
              %{sacc | usage: convert_usage(usage), finish_reason: finish_reason}
            else
              %{sacc | finish_reason: finish_reason}
            end

          new_acc =
            Map.put(new_acc, :passthrough, untranslated_response(event["response"] || %{}))

          {new_acc, chunks ++ [build_openai_chunk(%{}, finish_reason)]}

        _ ->
          {sacc, chunks}
      end
    end)
  end

  defp build_openai_chunk(delta, finish_reason \\ nil) do
    "data: " <>
      Jason.encode!(%{
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
      }) <>
      "\n\n"
  end

  @doc false
  def convert_usage(usage) do
    base = %{
      "prompt_tokens" => usage["input_tokens"],
      "completion_tokens" => usage["output_tokens"],
      "total_tokens" => usage["total_tokens"]
    }

    case usage do
      %{"input_tokens_details" => details} ->
        Map.put(base, "prompt_tokens_details", details)

      _ ->
        base
    end
  end

  # ── Final response builder ────────────────────────────────────────────────

  @doc false
  def build_final_response(acc, meta) do
    tool_calls_list =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, tc} -> Map.delete(tc, :item_id) end)

    message =
      %{"role" => "assistant", "content" => acc.content}
      |> then(fn m ->
        if tool_calls_list != [], do: Map.put(m, "tool_calls", tool_calls_list), else: m
      end)

    response = %{
      "model" => acc.model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => acc.finish_reason || "stop"
        }
      ],
      "_meta" => meta
    }

    response =
      if acc.usage do
        Map.put(response, "usage", acc.usage)
      else
        response
      end

    Map.put(response, Adapter.response_passthrough_key(), Map.get(acc, :passthrough) || %{})
  end

  # Consumed by the conversion above, or rebuilt by the egress from what was
  # consumed. Everything else on the provider's `response` object — the real
  # `resp_…` id a client needs for `previous_response_id`, `text.format`,
  # `instructions`, `incomplete_details`, whatever ships next — is invisible
  # unless carried, and the egress currently hardcodes several of them to
  # `nil`, which is a lie whenever the provider said otherwise.
  @translated_response_fields ~w(object created_at model status output output_text usage)

  defp untranslated_response(response) when is_map(response) do
    Map.drop(response, @translated_response_fields)
  end

  defp untranslated_response(_), do: %{}

  # ── Headers ────────────────────────────────────────────────────────────────

  @doc """
  Upstream headers: the proxy's credentials plus the client's forwardable
  headers, per the request-fidelity policy in `Adapter.build_forwarded_headers/2`.

  `chatgpt-account-id` is on the strip list, so a Codex client's own account id
  never reaches ChatGPT — but ours, added via `:extra_headers`, does: it is a
  proxy header and the policy only filters the *client's* side.
  """
  def build_headers(api_key, opts) do
    base = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    extra = Keyword.get(opts, :extra_headers, [])
    client_headers = Keyword.get(opts, :client_headers, [])

    Adapter.build_forwarded_headers(client_headers, base ++ extra)
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time
end
