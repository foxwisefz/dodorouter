defmodule DodoRouter.Proxy.Adapters.Anthropic do
  @moduledoc """
  Adapter for Anthropic Claude API.

  Converts OpenAI format to Anthropic Messages API format and back.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "anthropic",
    display_name: "Anthropic",
    key_slugs: ["anthropic", "anthropic_oauth"],
    key_display_names: %{
      "anthropic" => "Anthropic API",
      "anthropic_oauth" => "Claude subscription (setup-token)"
    },
    endpoints: %{
      "anthropic" => "https://api.anthropic.com/v1",
      "anthropic_oauth" => "https://api.anthropic.com/v1"
    },
    endpoint_path: "/messages",
    request_format: :anthropic,
    models:
      ~w(claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-5-sonnet-20241022 claude-3-5-haiku-20241022 claude-3-opus-20240229),
    color: "orange",
    short_description: "Claude Sonnet, Opus, Haiku"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Fidelity
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @response_passthrough_key Adapter.response_passthrough_key()

  @base_url "https://api.anthropic.com/v1"
  @timeout_ms 120_000
  @api_version "2023-06-01"
  @oauth_beta "oauth-2025-04-20"

  @doc """
  OAuth tokens from `claude setup-token` (prefix `sk-ant-oat`) authenticate
  with a Bearer header plus the oauth beta flag; API keys use `x-api-key`.
  """
  def auth_headers("sk-ant-oat" <> _rest = token) do
    [
      {"authorization", "Bearer " <> token},
      {"anthropic-beta", @oauth_beta},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]
  end

  def auth_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"Content-Type", "application/json"}
    ]
  end

  @doc """
  Upstream headers: the proxy's credentials plus the client's forwardable
  headers, per the request-fidelity policy in `Adapter.build_forwarded_headers/2`.

  Two headers here are ours only by default, because the generic proxy-wins
  collision rule is wrong for anything both sides legitimately set.

  `anthropic-beta` is *merged* before the policy runs, so exactly one header
  goes upstream carrying both lists. Letting ours win would discard the
  client's opt-ins in favour of a bare `oauth-2025-04-20` — including
  `extended-cache-ttl`, whose loss silently demotes an agent session from a 1h
  prompt cache to 5 minutes.

  `anthropic-version` *defers* to the client entirely, and we supply
  `#{@api_version}` only when they sent none (Anthropic requires the header,
  and OpenAI-format traffic falling back to this adapter has no version to
  forward). We hold the API key, not the API contract: the version a caller
  picked states which response shape they can parse, and none of the three
  strip reasons — replace it, it breaks the hop, it isn't theirs to send —
  apply to it.
  """
  def request_headers(api_key, client_headers) do
    merged = merged_beta(api_key, client_headers)

    proxy_headers =
      case merged do
        nil ->
          auth_headers(api_key)

        beta ->
          List.keystore(auth_headers(api_key), "anthropic-beta", 0, {"anthropic-beta", beta})
      end

    proxy_headers =
      if client_header(client_headers, "anthropic-version") do
        List.keydelete(proxy_headers, "anthropic-version", 0)
      else
        proxy_headers
      end

    headers = Adapter.build_forwarded_headers(client_headers, proxy_headers)

    # The policy above sees the client's anthropic-beta colliding with the
    # already-merged proxy header and records it as a drop. On the OAuth path
    # it wasn't dropped — it was merged, and logging it as lost would send the
    # next person debugging a cache miss looking for a header that is right
    # there. (On the api-key path `merged` is the client's list verbatim, so
    # the header is forwarded unchanged and there is nothing to report.)
    if merged && merged != client_beta(client_headers) do
      Fidelity.record_header_rewrite("anthropic-beta", "merged with #{@oauth_beta}")
    end

    headers
  end

  defp client_beta(client_headers), do: client_header(client_headers, "anthropic-beta")

  defp client_header(client_headers, name) do
    Enum.find_value(client_headers || [], fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: v
    end)
  end

  defp merged_beta(api_key, client_headers) do
    client_beta = client_beta(client_headers)

    case {client_beta, api_key} do
      {nil, _} -> nil
      {beta, "sk-ant-oat" <> _rest} -> ensure_oauth_beta(beta)
      {beta, _} -> beta
    end
  end

  defp ensure_oauth_beta(client_beta) do
    betas = client_beta |> String.split(",") |> Enum.map(&String.trim/1)

    if @oauth_beta in betas, do: client_beta, else: client_beta <> "," <> @oauth_beta
  end

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step)
    headers = request_headers(api_key, client_headers)

    payload_size_bytes = Adapter.record_outbound_body(body)
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

        response = convert_to_openai_format(response_body)
        {:ok, Map.put(response, "_meta", meta), %{headers: resp_headers}}

      {:ok, %{status: status, body: response_body, headers: resp_headers}} ->
        Logger.error(
          "[Anthropic] Non-200 response: status=#{status} body=#{inspect(response_body)}"
        )

        reason = Adapter.categorize_error(status, response_body)

        {:error, reason,
         %{
           status: status,
           body: response_body,
           latency_ms: latency(start_time),
           headers: resp_headers
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    url = @base_url <> "/messages"
    body = build_anthropic_request(request, step) |> Map.put("stream", true)
    headers = request_headers(api_key, client_headers)

    payload_size_bytes = Adapter.record_outbound_body(body)
    start_time = FinchTelemetry.mark_request_start()
    Process.delete(:__anthropic_stream_acc__)

    into_fun = fn
      {:data, data}, {req, resp} when resp.status != 200 ->
        Adapter.capture_streamed_error({:data, data}, {req, resp})

      {:data, data}, {req, resp} ->
        resp =
          if resp.private[:stream_acc] == nil do
            ttfb = System.monotonic_time(:millisecond) - start_time
            initial_acc = %{initial_stream_acc() | first_chunk_time: ttfb}
            # The head has arrived and nothing has been forwarded yet — the one
            # moment the egress can still put anything on its own response.
            Adapter.record_stream_response_headers(resp.headers)
            Req.Response.put_private(resp, :stream_acc, initial_acc)
          else
            resp
          end

        acc = resp.private.stream_acc

        case parse_anthropic_sse(data, acc.sse_buffer) do
          {{:events, events}, buffer} ->
            # Convert and forward as OpenAI format
            {acc, openai_chunks} = process_anthropic_events(acc, events)
            acc = %{acc | sse_buffer: buffer}
            # Park before forwarding, not after: the egress reads the real
            # message id from here while handling the very first chunk, and a
            # frame carrying `message_start` and a delta together would
            # otherwise hand it a stale accumulator.
            Process.put(:__anthropic_stream_acc__, acc)
            Enum.each(openai_chunks, &send_chunk.(&1))
            {:cont, {req, Req.Response.put_private(resp, :stream_acc, acc)}}

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

    Process.delete(:__anthropic_stream_acc__)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc = resp.private[:stream_acc] || initial_stream_acc()

        upload_ms = calculate_upload_ms(start_time)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: nil
        }

        {:ok, build_final_openai_response(acc, timing_meta), %{headers: resp.headers}}

      {:ok, %Req.Response{status: status, headers: resp_headers} = resp} ->
        body = Adapter.streamed_error_body(resp)
        reason = Adapter.categorize_error(status, body)

        {:error, reason,
         %{status: status, body: body, latency_ms: latency(start_time), headers: resp_headers}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @count_tokens_fields ~w(messages system tools tool_choice thinking)

  @doc """
  Builds the body for Anthropic's `/v1/messages/count_tokens` endpoint from an
  incoming Anthropic-format request. The step's model wins because that is the
  model dispatch would actually send the request to.
  """
  def build_count_tokens_request(params, %RoutingStep{} = step) do
    body =
      params
      |> Map.take(@count_tokens_fields)
      |> Map.put("model", step.model || params["model"])

    # Same translation as build_anthropic_request/2: Claude 5 models reject an
    # explicit thinking disable; omission is the portable spelling.
    case body["thinking"] do
      %{"type" => "disabled"} -> Map.delete(body, "thinking")
      _ -> body
    end
  end

  @doc """
  Forwards a count_tokens request to Anthropic. Returns `{:ok, body}` with the
  upstream response (`%{"input_tokens" => n}`) or `{:error, reason}`.
  """
  def count_tokens(params, %RoutingStep{} = step, api_key, client_headers \\ []) do
    url = @base_url <> "/messages/count_tokens"
    body = build_count_tokens_request(params, step)
    headers = request_headers(api_key, client_headers)

    case Req.post(url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        Logger.warning(
          "[Anthropic] count_tokens failed: status=#{status} body=#{inspect(response_body)}"
        )

        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_anthropic_request(request, step) do
    messages = request["messages"] || []
    {system_blocks, other_messages} = extract_system_blocks(messages)

    anthropic_messages =
      other_messages
      |> Enum.map(&convert_message_to_anthropic/1)
      |> merge_anthropic_content_blocks()

    body = %{
      "model" => step.model,
      "messages" => anthropic_messages,
      "max_tokens" => request["max_tokens"] || 4096
    }

    body =
      if system_blocks == [] do
        body
      else
        Map.put(body, "system", system_blocks)
      end

    # Optional params
    body =
      if request["temperature"],
        do: Map.put(body, "temperature", request["temperature"]),
        else: body

    body = if request["top_p"], do: Map.put(body, "top_p", request["top_p"]), else: body

    body =
      if request["stop"],
        do: Map.put(body, "stop_sequences", List.wrap(request["stop"])),
        else: body

    # Build the client's own `output_config` first — its `effort` outranks the
    # step default, and `inject_reasoning_effort/3` merges into whatever is
    # already there rather than replacing it.
    body = put_output_config(body, request)

    # Forward a client-supplied thinking block (if any) so it takes precedence
    # over the step-level default. An explicit disable is translated to
    # omission: Claude 5 models reject thinking.type=disabled outright, and on
    # older models omission means the same thing. It still counts as a client
    # choice, so the step-level effort default is not injected over it.
    body =
      case request["thinking"] do
        %{"type" => "disabled"} ->
          body

        nil ->
          Adapter.inject_reasoning_effort(body, step.reasoning_effort, :anthropic)

        thinking ->
          body
          |> Map.put("thinking", thinking)
          |> Adapter.inject_reasoning_effort(step.reasoning_effort, :anthropic)
      end

    body = put_tool_choice(body, request["tool_choice"], request["parallel_tool_calls"])

    # Tools
    body =
      if request["tools"] do
        anthropic_tools = Enum.map(request["tools"], &convert_tool_to_anthropic/1)
        Map.put(body, "tools", anthropic_tools)
      else
        body
      end

    restore_client_passthrough(body, request)
  end

  # An Anthropic-format request served by Anthropic never needed translating, so
  # the fields the OpenAI-shaped IR could not carry — `metadata`,
  # `context_management`, and whatever Anthropic ships next — go back on the
  # wire as the client sent them. `FallbackChain` only attaches them when the
  # formats match; a fallback to any other provider reports them as lost.
  #
  # `body` wins every collision. Belt and braces: the passthrough is built from
  # the keys the converter did *not* consume, so it cannot contain `model`,
  # `max_tokens`, `thinking`, or anything else routing owns.
  defp restore_client_passthrough(body, request) do
    case Adapter.client_passthrough(request) do
      fields when map_size(fields) == 0 -> body
      fields -> Map.merge(fields, body)
    end
  end

  # OpenAI tool_choice -> Anthropic. Inverse of AnthropicFormat.put_tool_choice/2;
  # OpenAI's sibling `parallel_tool_calls` folds into the choice object here.
  defp put_tool_choice(body, nil, _parallel), do: body

  defp put_tool_choice(body, tool_choice, parallel) do
    choice =
      case tool_choice do
        "auto" ->
          %{"type" => "auto"}

        "required" ->
          %{"type" => "any"}

        "none" ->
          %{"type" => "none"}

        %{"type" => "function", "function" => %{"name" => name}} ->
          %{"type" => "tool", "name" => name}

        _ ->
          nil
      end

    cond do
      is_nil(choice) ->
        body

      parallel == false ->
        Map.put(body, "tool_choice", Map.put(choice, "disable_parallel_tool_use", true))

      true ->
        Map.put(body, "tool_choice", choice)
    end
  end

  # Anthropic expresses structured outputs and reasoning depth in one
  # `output_config` object; rebuild it from the OpenAI-shaped fields.
  defp put_output_config(body, request) do
    output_config =
      %{}
      |> maybe_put_format(request["response_format"])
      |> maybe_put_effort(request["reasoning_effort"])

    if map_size(output_config) == 0 do
      body
    else
      Map.put(body, "output_config", output_config)
    end
  end

  defp maybe_put_format(config, %{"type" => "json_schema", "json_schema" => json_schema}) do
    case json_schema["schema"] do
      nil -> config
      schema -> Map.put(config, "format", %{"type" => "json_schema", "schema" => schema})
    end
  end

  defp maybe_put_format(config, _), do: config

  defp maybe_put_effort(config, effort) when is_binary(effort) and effort != "",
    do: Map.put(config, "effort", effort)

  defp maybe_put_effort(config, _), do: config

  # Hoists system messages into Anthropic's top-level system array, preserving
  # block boundaries and per-block cache_control — joining blocks would slide
  # client cache breakpoints to the end of the joined text and bust prompt
  # caching whenever content after the breakpoint changes.
  defp extract_system_blocks(messages) do
    {system_msgs, other} = Enum.split_with(messages, &(&1["role"] == "system"))

    blocks =
      Enum.flat_map(system_msgs, fn msg ->
        case msg["content"] do
          content when is_binary(content) ->
            block = %{"type" => "text", "text" => content}

            if msg["cache_control"],
              do: [Map.put(block, "cache_control", msg["cache_control"])],
              else: [block]

          content when is_list(content) ->
            content
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map(&Map.take(&1, ["type", "text", "cache_control"]))

          _ ->
            []
        end
      end)

    {blocks, other}
  end

  defp convert_message_to_anthropic(%{"role" => "assistant", "tool_calls" => tool_calls} = msg)
       when is_list(tool_calls) do
    content =
      [
        if(msg["content"] not in [nil, ""],
          do: %{"type" => "text", "text" => msg["content"]},
          else: nil
        )
        | Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => get_in(tc, ["function", "name"]),
              "input" =>
                case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
                  {:ok, decoded} -> decoded
                  _ -> %{}
                end
            }
          end)
      ]
      |> Enum.reject(&is_nil/1)

    content = if content == [], do: [%{"type" => "text", "text" => " "}], else: content

    # Add cache_control to last content block if present
    content =
      if msg["cache_control"] do
        List.update_at(content, -1, &Map.put(&1, "cache_control", msg["cache_control"]))
      else
        content
      end

    %{"role" => "assistant", "content" => content}
  end

  defp convert_message_to_anthropic(
         %{
           "role" => "tool",
           "tool_call_id" => id,
           "content" => content
         } = msg
       ) do
    block = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => content
    }

    block =
      if msg["cache_control"],
        do: Map.put(block, "cache_control", msg["cache_control"]),
        else: block

    %{"role" => "user", "content" => [block]}
  end

  defp convert_message_to_anthropic(%{"role" => role, "content" => content} = msg) do
    content = if is_list(content), do: normalize_content_blocks(content), else: content

    if msg["cache_control"] do
      content_blocks =
        if is_binary(content) do
          [%{"type" => "text", "text" => content || " "} | []]
        else
          content
        end

      content_blocks =
        List.update_at(content_blocks, -1, &Map.put(&1, "cache_control", msg["cache_control"]))

      %{"role" => role, "content" => content_blocks}
    else
      %{"role" => role, "content" => content}
    end
  end

  # Converts OpenAI-style content parts to native Anthropic blocks. Blocks that
  # are already Anthropic-shaped (image, tool_result, ...) pass through, so
  # both the OpenAI endpoint's parts arrays and native lists work.
  defp normalize_content_blocks(parts) do
    Enum.map(parts, fn
      %{"type" => "image_url", "image_url" => %{"url" => url}} = part ->
        block = image_url_to_anthropic(url)

        if part["cache_control"],
          do: Map.put(block, "cache_control", part["cache_control"]),
          else: block

      part ->
        part
    end)
  end

  @data_uri_regex ~r/^data:([^;,]+);base64,(.+)$/s

  defp image_url_to_anthropic(url) do
    case Regex.run(@data_uri_regex, url) do
      [_, media_type, data] ->
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
        }

      nil ->
        %{"type" => "image", "source" => %{"type" => "url", "url" => url}}
    end
  end

  defp convert_tool_to_anthropic(%{"function" => func} = tool) do
    anthropic_tool = %{
      "name" => func["name"],
      "description" => func["description"] || "",
      "input_schema" => func["parameters"] || %{"type" => "object", "properties" => %{}}
    }

    if tool["cache_control"],
      do: Map.put(anthropic_tool, "cache_control", tool["cache_control"]),
      else: anthropic_tool
  end

  defp merge_anthropic_content_blocks(messages) when is_list(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          if prev["role"] == msg["role"] and is_list(prev["content"]) and is_list(msg["content"]) do
            merged_content = prev["content"] ++ msg["content"]
            [Map.put(prev, "content", merged_content) | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def convert_to_openai_format(anthropic_response) do
    content_blocks = anthropic_response["content"] || []

    {text_content, tool_calls} =
      Enum.reduce(content_blocks, {"", []}, fn block, {text, tools} ->
        case block["type"] do
          "text" ->
            {text <> (block["text"] || ""), tools}

          "tool_use" ->
            tool_call = %{
              "id" => block["id"],
              "type" => "function",
              "function" => %{
                "name" => block["name"],
                "arguments" => Jason.encode!(block["input"] || %{})
              }
            }

            {text, tools ++ [tool_call]}

          _ ->
            {text, tools}
        end
      end)

    message = %{"role" => "assistant", "content" => text_content}
    message = if tool_calls != [], do: Map.put(message, "tool_calls", tool_calls), else: message

    finish_reason =
      case anthropic_response["stop_reason"] do
        "end_turn" -> "stop"
        "tool_use" -> "tool_calls"
        "max_tokens" -> "length"
        other -> other
      end

    usage =
      if anthropic_response["usage"] do
        cache_read = anthropic_response["usage"]["cache_read_input_tokens"]
        cache_write = anthropic_response["usage"]["cache_creation_input_tokens"]

        base = %{
          "prompt_tokens" => anthropic_response["usage"]["input_tokens"],
          "completion_tokens" => anthropic_response["usage"]["output_tokens"],
          "total_tokens" =>
            (anthropic_response["usage"]["input_tokens"] || 0) +
              (anthropic_response["usage"]["output_tokens"] || 0)
        }

        base =
          if cache_read,
            do: Map.put(base, "cache_read_tokens", cache_read),
            else: base

        if cache_write,
          do: Map.put(base, "cache_write_tokens", cache_write),
          else: base
      end

    response =
      %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      |> put_if(usage, "usage", usage)
      # The model Anthropic actually served — an alias like
      # `claude-sonnet-4-5` resolves to a dated snapshot upstream, and the
      # client should see the snapshot.
      |> put_if(anthropic_response["model"], "model", anthropic_response["model"])
      # Which stop string ended the turn. OpenAI's shape has no equivalent, so
      # it rides the IR as-is rather than being reinvented downstream — the
      # Anthropic egress used to hardcode `stop_sequence: nil`, which is a lie
      # whenever the client supplied stop_sequences and one of them matched.
      |> put_if(
        anthropic_response["stop_sequence"],
        "stop_sequence",
        anthropic_response["stop_sequence"]
      )

    # Everything Anthropic returned that the OpenAI-shaped IR has no place for
    # rides along for an Anthropic egress to restore — the response half of the
    # same rule the request side uses. `id` is in here rather than in the IR's
    # own `id`: it names a message in Anthropic's store (cache diagnostics
    # reference it), and an OpenAI-family client expects a `chatcmpl-` id, so
    # it must not become the IR's.
    Map.put(response, @response_passthrough_key, untranslated_response(anthropic_response))
  end

  # Consumed above, or rebuilt by the egress from what was consumed. Anything
  # else Anthropic sends — `context_management` applied edits, `stop_details`
  # for a refusal, `container`, `service_tier`, and whatever ships next — is
  # invisible to the client unless carried.
  @translated_response_fields ~w(content stop_reason usage model stop_sequence)

  # The block types the reduction above knows how to render into the IR.
  @translated_block_types ~w(text tool_use)

  defp untranslated_response(anthropic_response) do
    anthropic_response
    |> Map.drop(@translated_response_fields)
    |> carry_native_content(anthropic_response["content"])
  end

  # `content` is normally rebuilt by the egress from the flattened text and
  # tool calls, so carrying it would be noise — and would make every ordinary
  # Anthropic response report `content` as lost to an OpenAI-family client,
  # which it wasn't.
  #
  # The moment a block the reduction cannot render appears — `thinking`,
  # `redacted_thinking`, a server-tool block, the `fallback` block Opus 5 and
  # Fable 5 emit when a refusal is re-served — the flattened view is no longer
  # a faithful summary, so the whole native list travels and an Anthropic
  # egress restores it 1:1. The whole list, not just the untranslatable part:
  # the reduction concatenates text blocks, so their original boundaries and
  # interleaving cannot be recovered from what it produced.
  #
  # This matters beyond display. Anthropic requires thinking blocks be echoed
  # back unchanged to continue a conversation on the same model, and rejects
  # ones whose content was modified — so a client that never receives them
  # cannot resume its own conversation.
  defp carry_native_content(passthrough, content) when is_list(content) do
    if Enum.all?(content, &(&1["type"] in @translated_block_types)) do
      passthrough
    else
      Map.put(passthrough, "content", content)
    end
  end

  defp carry_native_content(passthrough, _content), do: passthrough

  defp put_if(map, nil, _key, _value), do: map
  defp put_if(map, _present, key, value), do: Map.put(map, key, value)

  defp parse_anthropic_sse(data, buffer) do
    combined = buffer <> data
    lines = String.split(combined, "\n")

    {complete_lines, buffer} =
      case List.last(lines) do
        "" -> {Enum.drop(lines, -1), ""}
        last when byte_size(last) > 0 -> {Enum.drop(lines, -1), last}
      end

    complete_lines = complete_lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(events, &(&1["type"] == "message_stop")) -> {:done, ""}
      events == [] -> {:skip, buffer}
      true -> {{:events, events}, buffer}
    end
  end

  @doc false
  def initial_stream_acc do
    %{
      content: "",
      tool_calls: [],
      block_tools: %{},
      usage: nil,
      stop_reason: nil,
      first_chunk_time: nil,
      sse_buffer: "",
      # Anthropic's own `msg_…` id, off `message_start`. It arrives before any
      # delta, so the egress still has it in hand when it emits its own
      # `message_start` — see `process_anthropic_events/2`.
      message_id: nil,
      # Native fields off `message_delta` that the OpenAI chunk shape has no
      # place for — `context_management` applied edits, `stop_details` behind a
      # refusal, the `stop_sequence` that actually matched. Collected here
      # because the tail event is emitted after the client's `message_delta`
      # can still carry them. Other `message_start` fields (`container`) are
      # already on the wire by then and cannot be back-filled.
      passthrough: %{}
    }
  end

  @doc """
  Anthropic's real message id for the stream in flight, or `nil`.

  Read by the Anthropic egress at the moment it opens its own stream. The
  adapter runs inline in the caller's process — the same property `Fidelity`
  relies on — and parks the accumulator there as it goes.
  """
  def stream_message_id do
    case Process.get(:__anthropic_stream_acc__) do
      %{message_id: id} -> id
      _ -> nil
    end
  end

  @doc false
  def process_anthropic_events(acc, events) do
    Enum.reduce(events, {acc, []}, fn event, {acc, chunks} ->
      case event["type"] do
        # Anthropic sends this before any delta, so the real `msg_…` id is in
        # hand before the egress has to emit its own `message_start` — early
        # enough to use it rather than synthesise one. It names a message in
        # Anthropic's store, which is what `previous_message_id` cache
        # diagnostics refer to; a synthesised id cannot be used for that.
        "message_start" ->
          {%{acc | message_id: get_in(event, ["message", "id"])}, chunks}

        "content_block_start" ->
          case event["content_block"] do
            %{"type" => "tool_use"} = block ->
              tool_idx = length(acc.tool_calls)

              tool_call = %{
                "id" => block["id"],
                "type" => "function",
                "function" => %{"name" => block["name"], "arguments" => ""}
              }

              new_acc = %{
                acc
                | tool_calls: acc.tool_calls ++ [tool_call],
                  block_tools: Map.put(acc.block_tools, event["index"], tool_idx)
              }

              chunk =
                build_openai_stream_chunk(%{
                  "tool_calls" => [Map.put(tool_call, "index", tool_idx)]
                })

              {new_acc, chunks ++ [chunk]}

            _ ->
              {acc, chunks}
          end

        "content_block_delta" ->
          delta = event["delta"]

          case delta["type"] do
            "text_delta" ->
              new_acc = %{acc | content: acc.content <> (delta["text"] || "")}
              chunk = build_openai_stream_chunk(%{"content" => delta["text"]})
              {new_acc, chunks ++ [chunk]}

            "input_json_delta" ->
              case Map.fetch(acc.block_tools, event["index"]) do
                {:ok, tool_idx} ->
                  partial = delta["partial_json"] || ""

                  tool_calls =
                    List.update_at(acc.tool_calls, tool_idx, fn tc ->
                      update_in(tc, ["function", "arguments"], &(&1 <> partial))
                    end)

                  chunk =
                    build_openai_stream_chunk(%{
                      "tool_calls" => [
                        %{"index" => tool_idx, "function" => %{"arguments" => partial}}
                      ]
                    })

                  {%{acc | tool_calls: tool_calls}, chunks ++ [chunk]}

                :error ->
                  {acc, chunks}
              end

            _ ->
              {acc, chunks}
          end

        "message_delta" ->
          new_acc = %{
            acc
            | stop_reason: event["delta"]["stop_reason"],
              passthrough: Map.merge(acc.passthrough, message_delta_passthrough(event))
          }

          usage = event["usage"]

          new_acc =
            if usage do
              cache_read = usage["cache_read_input_tokens"]
              cache_write = usage["cache_creation_input_tokens"]

              base = %{
                "prompt_tokens" =>
                  usage["input_tokens"] || (acc.usage && acc.usage["prompt_tokens"]),
                "completion_tokens" =>
                  usage["output_tokens"] || (acc.usage && acc.usage["completion_tokens"]),
                "total_tokens" =>
                  (usage["input_tokens"] || (acc.usage && acc.usage["prompt_tokens"]) || 0) +
                    (usage["output_tokens"] || (acc.usage && acc.usage["completion_tokens"]) || 0)
              }

              # Preserve cache fields from previous chunk if new ones aren't provided
              base =
                cond do
                  cache_read ->
                    Map.put(base, "cache_read_tokens", cache_read)

                  acc.usage && acc.usage["cache_read_tokens"] ->
                    Map.put(base, "cache_read_tokens", acc.usage["cache_read_tokens"])

                  true ->
                    base
                end

              base =
                cond do
                  cache_write ->
                    Map.put(base, "cache_write_tokens", cache_write)

                  acc.usage && acc.usage["cache_write_tokens"] ->
                    Map.put(base, "cache_write_tokens", acc.usage["cache_write_tokens"])

                  true ->
                    base
                end

              %{new_acc | usage: base}
            else
              new_acc
            end

          {new_acc, chunks}

        _ ->
          {acc, chunks}
      end
    end)
  end

  # `type`, `delta.stop_reason` and `usage` are translated into the OpenAI
  # chunk shape; everything else on the tail event is not. `delta` is unwrapped
  # so the egress can put its contents straight back into the `delta` it emits
  # — that is where `stop_sequence` lives, which the egress otherwise hardcodes
  # to nil and thereby lies about whenever a client's stop sequence matched.
  defp message_delta_passthrough(event) do
    delta = Map.drop(event["delta"] || %{}, ["stop_reason"])
    top = Map.drop(event, ["type", "delta", "usage"])

    Map.merge(top, delta)
  end

  defp build_openai_stream_chunk(delta) do
    chunk = %{
      "choices" => [%{"index" => 0, "delta" => delta}]
    }

    "data: #{Jason.encode!(chunk)}\n\n"
  end

  @doc false
  def build_final_openai_response(acc, timing_meta) do
    message = %{"role" => "assistant", "content" => acc.content}

    message =
      if acc.tool_calls != [],
        do: Map.put(message, "tool_calls", acc.tool_calls),
        else: message

    finish_reason =
      case acc.stop_reason do
        "end_turn" -> "stop"
        "tool_use" -> "tool_calls"
        "max_tokens" -> "length"
        other -> other || "stop"
      end

    meta = %{
      "ttfb_ms" => acc.first_chunk_time,
      "upload_ms" => timing_meta.upload_ms,
      "payload_size_bytes" => timing_meta.payload_size_bytes,
      "provider_processing_ms" => timing_meta.provider_processing_ms
    }

    response = %{
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}],
      "_meta" => meta
    }

    response = if acc.usage, do: Map.put(response, "usage", acc.usage), else: response

    if map_size(acc.passthrough) == 0 do
      response
    else
      Map.put(response, @response_passthrough_key, acc.passthrough)
    end
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
