defmodule DodoRouter.Proxy.Adapter do
  @moduledoc """
  Behaviour for LLM provider adapters.
  """

  alias DodoRouter.Proxy.Fidelity
  alias DodoRouter.Routers.RoutingStep

  @type request :: map()
  @type response :: map()
  @type error_reason ::
          :rate_limited
          | :server_error
          | :timeout
          | :model_unavailable
          | :bad_request
          | :auth_error
          | :content_policy
          | :context_overflow
          | :unknown

  @callback call(request(), RoutingStep.t(), api_key :: String.t(), client_headers :: list()) ::
              {:ok, response(), meta :: map()} | {:error, error_reason(), details :: map()}

  @callback stream(
              request(),
              RoutingStep.t(),
              api_key :: String.t(),
              send_chunk :: (binary() -> :ok),
              client_headers :: list()
            ) ::
              {:ok, response(), meta :: map()} | {:error, error_reason(), details :: map()}

  @doc """
  Categorizes HTTP status codes into error reasons.
  """
  def categorize_error(status, body \\ %{})

  def categorize_error(429, _body), do: :rate_limited
  def categorize_error(401, _body), do: :auth_error
  def categorize_error(403, _body), do: :auth_error
  def categorize_error(503, _body), do: :model_unavailable

  def categorize_error(400, body) do
    message = get_error_message(body)

    cond do
      context_overflow?(body, message) -> :context_overflow
      String.contains?(message, "content") -> :content_policy
      String.contains?(message, "policy") -> :content_policy
      true -> :bad_request
    end
  end

  def categorize_error(413, _body) do
    :context_overflow
  end

  def categorize_error(status, _body) when status >= 500, do: :server_error

  def categorize_error(_status, body) do
    if context_overflow?(body), do: :context_overflow, else: :unknown
  end

  @doc """
  Determines if an error should trigger fallback to next provider.
  """
  def should_fallback?(:rate_limited), do: true
  def should_fallback?(:server_error), do: true
  def should_fallback?(:timeout), do: true
  def should_fallback?(:model_unavailable), do: true
  def should_fallback?(:auth_error), do: true
  def should_fallback?(:unknown), do: true
  def should_fallback?(:bad_request), do: true
  def should_fallback?(:content_policy), do: true
  def should_fallback?(:context_overflow), do: true
  def should_fallback?(_), do: false

  @doc """
  Extracts error message from response body.
  """
  def get_error_message(%{"error" => %{"message" => msg}}), do: String.downcase(msg)
  def get_error_message(%{"message" => msg}), do: String.downcase(msg)
  def get_error_message(_), do: ""

  @doc """
  Detects context window overflow from provider response.

  Providers return this in different formats — status codes, finish_reasons,
  error codes, or message text. Each new model must be tested to discover
  its specific overflow signal.
  """
  def context_overflow?(body, message \\ nil)

  # z.ai returns HTTP 200 with finish_reason: "model_context_window_exceeded"
  def context_overflow?(
        %{"choices" => [%{"finish_reason" => "model_context_window_exceeded"} | _]},
        _
      ) do
    true
  end

  # OpenAI returns error.code: "context_length_exceeded"
  def context_overflow?(%{"error" => %{"code" => "context_length_exceeded"}}, _) do
    true
  end

  # Stream errors from OpenAI with type: "error"
  def context_overflow?(
        %{"type" => "error", "error" => %{"code" => "context_length_exceeded"}},
        _
      ) do
    true
  end

  def context_overflow?(body, nil) do
    context_overflow?(body, get_error_message(body))
  end

  def context_overflow?(_body, message) when is_binary(message) do
    patterns = [
      # Anthropic
      ~r/prompt is too long/i,
      # Amazon Bedrock
      ~r/input is too long for requested model/i,
      # OpenAI (message text)
      ~r/exceeds the context window/i,
      # Google (Gemini)
      ~r/input token count.*exceeds the maximum/i,
      # xAI (Grok)
      ~r/maximum prompt length is \d+/i,
      # Groq
      ~r/reduce the length of the messages/i,
      # OpenRouter, DeepSeek, vLLM
      ~r/maximum context length is \d+ tokens/i,
      # GitHub Copilot
      ~r/exceeds the limit of \d+/i,
      # llama.cpp
      ~r/exceeds the available context size/i,
      # LM Studio
      ~r/greater than the context length/i,
      # MiniMax
      ~r/context window exceeds limit/i,
      # Kimi / Moonshot
      ~r/exceeded model token limit/i,
      # Generic fallback
      ~r/context[_ ]length[_ ]exceeded/i,
      # vLLM
      ~r/context length is only \d+ tokens/i,
      # vLLM
      ~r/input length.*exceeds.*context length/i,
      # Ollama
      ~r/prompt too long; exceeded (?:max )?context length/i,
      # Mistral
      ~r/too large for model(?: with \d+ maximum context length)?/i,
      # z.ai (in error text)
      ~r/model_context_window_exceeded/i
    ]

    Enum.any?(patterns, &Regex.match?(&1, message))
  end

  def context_overflow?(_, _), do: false

  @doc """
  Extracts usage from response, including cache tokens from providers.

  Providers report cache tokens in different locations:
  - Anthropic: usage.cache_read_input_tokens, usage.cache_creation_input_tokens
  - OpenAI/Groq/xAI/Mistral: usage.prompt_tokens_details.cached_tokens
  - Google: usageMetadata.cachedContentTokenCount
  - DeepSeek: usage.prompt_cache_hit_tokens
  """
  def extract_usage(%{"usage" => usage}) do
    %{
      prompt_tokens: usage["prompt_tokens"],
      completion_tokens: usage["completion_tokens"],
      total_tokens: usage["total_tokens"],
      cache_read_tokens: extract_cache_read_tokens(usage),
      cache_write_tokens: extract_cache_write_tokens(usage)
    }
  end

  def extract_usage(_),
    do: %{
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil
    }

  defp extract_cache_read_tokens(usage) do
    # Anthropic: cache_read_input_tokens
    # OpenAI/Groq/xAI/Mistral: prompt_tokens_details.cached_tokens
    # DeepSeek: prompt_cache_hit_tokens
    # Already-normalized by adapter (cache_read_tokens)
    usage["cache_read_input_tokens"] ||
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      usage["prompt_cache_hit_tokens"] ||
      usage["cache_read_tokens"]
  end

  defp extract_cache_write_tokens(usage) do
    # Anthropic: cache_creation_input_tokens
    # Already-normalized by adapter (cache_write_tokens)
    usage["cache_creation_input_tokens"] ||
      usage["cache_write_tokens"]
  end

  @doc """
  Detects call type from request and response.
  """
  def detect_call_type(request, response) do
    has_tools = is_list(request["tools"]) and length(request["tools"]) > 0

    used_tools =
      case response do
        %{"choices" => [%{"message" => %{"tool_calls" => calls}} | _]} when is_list(calls) ->
          Enum.map(calls, fn call -> get_in(call, ["function", "name"]) end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    cond do
      length(used_tools) > 0 -> {"tool_call", used_tools}
      has_tools -> {"tool_enabled_completion", []}
      true -> {"completion", []}
    end
  end

  # Standard OpenAI-compatible fields that upstream providers accept.
  # Everything else (`router_slug`, client-invented extras, …) is stripped.
  #
  # `parallel_tool_calls` belongs here: it is a documented Chat Completions
  # parameter, both ingress converters produce it (AnthropicFormat derives it
  # from `tool_choice.disable_parallel_tool_use`, ResponsesFormat passes it
  # through), and the Anthropic adapter honours it on egress. Leaving it out
  # meant an identical request kept the client's "do not parallelise" intent on
  # an Anthropic step and silently lost it on every OpenAI-family fallback.
  # `Map.take/2` means it only travels when the client actually sent it.
  @allowed_request_fields ~w(
    model messages temperature top_p max_tokens max_completion_tokens
    stream stream_options stop frequency_penalty presence_penalty
    tools tool_choice parallel_tool_calls response_format seed n
    logprobs top_logprobs user reasoning_effort thinking
  )

  @doc """
  Strips non-standard fields from the incoming request body before
  forwarding to an upstream provider.

  Clients may send extra fields (e.g. `router_slug`) that are not part of the
  provider's API. This whitelist ensures only recognized fields are forwarded,
  preventing 400 Bad Request errors.
  """
  def sanitize_request(request) when is_map(request) do
    request
    |> record_dropped_fields()
    |> Map.take(@allowed_request_fields)
    |> normalize_max_completion_tokens()
    |> sanitize_messages()
  end

  def sanitize_request(request), do: request

  # Injected by the router from the URL path or by the proxy itself — the
  # client never sent them, so removing them is not a fidelity loss and
  # reporting them would put noise on every single request log.
  @proxy_owned_request_fields ~w(router_slug)

  defp record_dropped_fields(request) do
    request
    |> Map.keys()
    |> Enum.reject(&(&1 in @allowed_request_fields or &1 in @proxy_owned_request_fields))
    |> Enum.sort()
    |> Fidelity.record_dropped_body_fields(:not_in_provider_allowlist)

    request
  end

  @doc """
  Accumulates raw response data while streaming a non-200 response.

  Streaming adapters consume the response with `Req` `into:` functions that
  parse SSE events. On an error status the provider sends a plain JSON error
  body instead of SSE — parsing it as SSE silently discards it. Adapters call
  this from their `into:` function when `resp.status != 200` so the error
  body is preserved for logging (see `streamed_error_body/1`).
  """
  def capture_streamed_error({:data, data}, {req, resp}) do
    buffered = (resp.private[:error_body] || "") <> data
    {:cont, {req, Req.Response.put_private(resp, :error_body, buffered)}}
  end

  @doc """
  Returns the error body captured by `capture_streamed_error/2`, decoded as
  JSON when possible, falling back to the raw string or `Req.Response.body`.
  """
  def streamed_error_body(%Req.Response{} = resp) do
    case resp.private[:error_body] do
      nil ->
        resp.body

      raw ->
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          {:error, _} -> raw
        end
    end
  end

  # OpenAI introduced max_completion_tokens as a replacement for max_tokens.
  # Some providers only accept max_tokens, so normalize if only the newer key is present.
  defp normalize_max_completion_tokens(request) do
    cond do
      Map.has_key?(request, "max_tokens") ->
        # max_tokens already set — drop max_completion_tokens to avoid sending both
        Map.delete(request, "max_completion_tokens")

      Map.has_key?(request, "max_completion_tokens") ->
        request
        |> Map.put("max_tokens", request["max_completion_tokens"])
        |> Map.delete("max_completion_tokens")

      true ->
        request
    end
  end

  # Remove non-standard keys from individual message objects.
  # Also normalize tool message content from array format to string.
  # Some clients send content as [{"type": "text", "text": "..."}] but many
  # providers only accept a plain string for tool messages.
  #
  # Note: reasoning_details is kept here so provider-specific adapters can
  # convert it (e.g. Moonshot kimi-k2 needs it as reasoning_content).
  defp sanitize_messages(%{"messages" => messages} = request) when is_list(messages) do
    sanitized =
      Enum.map(messages, fn msg ->
        msg
        |> Map.take(
          ~w(role content name tool_calls tool_call_id function_call reasoning_details reasoning_content cache_control)
        )
        |> normalize_message_content()
        |> migrate_function_call()
      end)

    Map.put(request, "messages", sanitized)
  end

  defp sanitize_messages(request), do: request

  # Normalize content from array format to string.
  # OpenAI-style: [{"type": "text", "text": "..."}] -> "..."
  # System parts arrays come from the Anthropic endpoint's block-preserving
  # conversion; OpenAI-family providers cache by prefix automatically, so
  # flattening (and dropping the embedded cache_control keys) is safe here.
  defp normalize_message_content(%{"content" => content, "role" => role} = msg)
       when is_list(content) and role in ["tool", "user", "system"] do
    normalized =
      content
      |> Enum.map(fn
        %{"type" => "text", "text" => text} -> text
        %{"text" => text} -> text
        other -> Jason.encode!(other)
      end)
      |> Enum.join("\n")

    Map.put(msg, "content", normalized)
  end

  defp normalize_message_content(msg), do: msg

  @doc """
  Merges consecutive messages with the same role into a single message.
  Required for providers like Anthropic and Google that enforce alternating roles.

  For tool messages (which become "user" role in Anthropic), merges content blocks.
  For regular messages, concatenates text content.
  """
  def merge_consecutive_roles(messages) when is_list(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          if same_effective_role?(prev["role"], msg["role"]) do
            [merge_messages(prev, msg) | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp same_effective_role?("tool", "tool"), do: true
  defp same_effective_role?(a, b), do: a == b

  defp merge_messages(prev, msg) do
    cond do
      prev["role"] == "tool" and msg["role"] == "tool" ->
        merged_content = (prev["content"] || "") <> "\n" <> (msg["content"] || "")
        Map.put(prev, "content", merged_content)

      prev["role"] == "assistant" and msg["role"] == "assistant" ->
        prev_text = prev["content"] || ""
        msg_text = msg["content"] || ""
        prev_tool_calls = prev["tool_calls"] || []
        msg_tool_calls = msg["tool_calls"] || []

        merged =
          prev
          |> Map.put("content", prev_text <> msg_text)

        merged =
          if prev_tool_calls != [] or msg_tool_calls != [],
            do: Map.put(merged, "tool_calls", prev_tool_calls ++ msg_tool_calls),
            else: Map.delete(merged, "tool_calls")

        merged

      true ->
        prev_text = text_content(prev)
        msg_text = text_content(msg)
        Map.merge(prev, %{"content" => prev_text <> "\n" <> msg_text})
    end
  end

  defp text_content(%{"content" => c}) when is_binary(c), do: c
  defp text_content(%{"content" => c}) when is_list(c), do: flatten_content_list(c)
  defp text_content(_), do: ""

  defp flatten_content_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  @doc """
  Converts deprecated function_call field to modern tool_calls format.
  """
  def migrate_function_call(%{"function_call" => fc} = msg) when is_map(fc) do
    tool_call = %{
      "id" => msg["tool_call_id"] || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => fc["name"],
        "arguments" => fc["arguments"] || "{}"
      }
    }

    msg
    |> Map.put("tool_calls", [tool_call])
    |> Map.delete("function_call")
  end

  def migrate_function_call(msg), do: msg

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  # Request-fidelity policy (brain/main.md): client headers reach the provider
  # by default, INCLUDING on fallback to a different provider. A header is
  # stripped only for one of three stated reasons, below. This function is the
  # single place that policy lives, and it is provider agnostic — so step 1 and
  # step 5 of a fallback chain behave identically, with no notion of "is this a
  # fallback?" to get wrong.

  # 1. We must replace it: the proxy authenticates with its own credentials.
  @proxy_overrides ~w(authorization content-type x-api-key)

  # 2a. The provider will break. content-length/transfer-encoding describe a
  # body we rewrite, so they are lies by the time we forward. accept-encoding
  # corrupts streamed responses. The rest cannot survive a hop by definition.
  @transport_headers ~w(
    host connection content-length transfer-encoding upgrade
    proxy-authorization proxy-authenticate te trailer keep-alive
    accept-encoding
  )

  # 2b. The provider will break: these name the CLIENT's account or project on
  # a provider we authenticate to with OUR key, so forwarding them either 401s
  # or bills the wrong account. Note openai-beta is deliberately absent — it is
  # a feature opt-in like anthropic-beta, not account scope, so it forwards.
  @provider_scoped_headers ~w(
    openai-organization openai-project
    chatgpt-account-id
    x-goog-api-key x-goog-user-project
  )

  # 3. Not the client's to send. `cookie` on a browser-originated request
  # carries the user's own DodoRouter session — forwarding it would hand a
  # third party our auth credential. The rest are added by our edge (Caddy),
  # not by the caller, and disclose the end user's real IP and our internal
  # hostnames.
  @non_client_headers ~w(
    cookie
    forwarded via x-real-ip x-original-forwarded-for x-original-url
  )

  # Matched by prefix rather than enumerated: Caddy's config lives on the
  # server, not in this repo, so the edge can start emitting a new
  # `x-forwarded-*` with no change here and an enumerated list would go stale
  # silently. `cf-` costs nothing and covers the day something fronts Caddy.
  @non_client_prefixes ~w(x-forwarded- cf-)

  def build_forwarded_headers(client_headers, proxy_headers) when is_list(client_headers) do
    proxy_keys = MapSet.new(proxy_headers, fn {key, _} -> String.downcase(key) end)

    {dropped, filtered} =
      Enum.split_with(client_headers, fn {key, _} ->
        strip_reason(String.downcase(to_string(key)), proxy_keys) != nil
      end)

    outbound = filtered ++ proxy_headers

    Fidelity.record_headers(
      Enum.map(dropped, fn {key, _} ->
        key = String.downcase(to_string(key))
        {key, strip_reason(key, proxy_keys)}
      end),
      outbound
    )

    outbound
  end

  def build_forwarded_headers(client_headers, proxy_headers) when is_nil(client_headers) do
    Fidelity.record_headers([], proxy_headers)
    proxy_headers
  end

  # The reason a client header does not reach the provider, or nil when it
  # does. Recording the reason alongside the drop is what keeps the strip list
  # from decaying into folklore: every entry in a log can be traced back to one
  # of the three stated rationales rather than to someone's memory of an outage.
  defp strip_reason(key, proxy_keys) do
    cond do
      key in @proxy_overrides -> :replaced_by_proxy
      key in @transport_headers -> :transport
      key in @provider_scoped_headers -> :account_scoped
      key in @non_client_headers -> :not_client_sent
      String.starts_with?(key, @non_client_prefixes) -> :not_client_sent
      MapSet.member?(proxy_keys, key) -> :proxy_value_wins
      true -> nil
    end
  end

  # SSE parsing utilities

  @doc """
  Parses SSE data with buffering to handle lines split across HTTP chunks.
  Call with an empty buffer on the first chunk, then pass the returned buffer
  on subsequent chunks.

  Returns `{result, buffer}` where result is the parsed chunks or :done/:skip.
  """
  def parse_sse_chunk(data, buffer \\ "") do
    combined = buffer <> data
    lines = String.split(combined, "\n")

    {complete_lines, buffer} =
      case List.last(lines) do
        "" -> {Enum.drop(lines, -1), ""}
        last when byte_size(last) > 0 -> {Enum.drop(lines, -1), last}
      end

    has_done = Enum.any?(complete_lines, &is_done_line/1)

    chunks =
      complete_lines
      |> Enum.filter(&is_data_line/1)
      |> Enum.reject(&is_done_line/1)
      |> Enum.flat_map(fn line ->
        json = extract_json(line)

        case Jason.decode(json) do
          {:ok, parsed} -> [parsed]
          _ -> []
        end
      end)

    result =
      cond do
        has_done and chunks == [] -> :done
        has_done -> {:chunks_then_done, chunks}
        chunks == [] -> :skip
        true -> {:chunks, chunks}
      end

    {result, buffer}
  end

  defp is_data_line(line),
    do: String.starts_with?(line, "data:") or String.starts_with?(line, "data: ")

  defp is_done_line(line),
    do: String.starts_with?(line, "data: [DONE]") or String.starts_with?(line, "data:[DONE]")

  defp extract_json(line) do
    line
    |> String.replace_prefix("data: ", "")
    |> String.replace_prefix("data:", "")
  end

  # ===========================================================================
  # Request Transformations
  # ===========================================================================

  @doc """
  Checks if a request can be handled by a model based on capabilities.
  Returns :ok or {:error, reason}.
  """
  def can_handle?(request, model) do
    cond do
      has_images?(request) and not model.supports_vision ->
        {:error, :no_vision_support}

      has_tools?(request) and not model.supports_function_calling ->
        {:error, :no_tool_support}

      true ->
        :ok
    end
  end

  @doc """
  Checks if request contains image content.
  """
  def has_images?(request) do
    messages = request["messages"] || []

    Enum.any?(messages, fn msg ->
      case msg["content"] do
        content when is_list(content) ->
          Enum.any?(content, fn
            %{"type" => "image_url"} -> true
            %{"type" => "image"} -> true
            _ -> false
          end)

        _ ->
          false
      end
    end)
  end

  @doc """
  Checks if request uses tools.
  """
  def has_tools?(request) do
    tools = request["tools"] || []
    is_list(tools) and length(tools) > 0
  end

  @doc """
  Converts content arrays to strings for providers that don't support list format.
  Only converts text-only content; preserves arrays with images/audio.
  """
  def flatten_content_to_string(request) do
    messages = request["messages"] || []

    updated =
      Enum.map(messages, fn msg ->
        case msg["content"] do
          content when is_list(content) ->
            if all_text_content?(content) do
              text =
                content
                |> Enum.map(fn
                  %{"type" => "text", "text" => t} -> t
                  %{"text" => t} -> t
                  _ -> ""
                end)
                |> Enum.join("")

              Map.put(msg, "content", text)
            else
              msg
            end

          _ ->
            msg
        end
      end)

    Map.put(request, "messages", updated)
  end

  defp all_text_content?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => "text"} -> true
      %{"type" => type} when type in ["image_url", "image", "audio", "file", "video_url"] -> false
      _ -> true
    end)
  end

  @doc """
  Strips `name` field from messages (some providers don't support it).
  Options:
    - :all - strip from all messages
    - :non_tool - strip from all except tool messages
  """
  def strip_name_from_messages(request, mode \\ :all) do
    messages = request["messages"] || []

    updated =
      Enum.map(messages, fn msg ->
        should_strip =
          case mode do
            :all -> true
            :non_tool -> msg["role"] != "tool"
          end

        if should_strip, do: Map.delete(msg, "name"), else: msg
      end)

    Map.put(request, "messages", updated)
  end

  @doc """
  Removes empty assistant messages (some providers reject them).
  """
  def filter_empty_assistant_messages(request) do
    messages = request["messages"] || []

    updated =
      Enum.reject(messages, fn msg ->
        msg["role"] == "assistant" and
          empty_content?(msg["content"]) and
          empty_or_nil?(msg["tool_calls"])
      end)

    Map.put(request, "messages", updated)
  end

  defp empty_content?(nil), do: true
  defp empty_content?(""), do: true
  defp empty_content?([]), do: true
  defp empty_content?(_), do: false

  defp empty_or_nil?(nil), do: true
  defp empty_or_nil?([]), do: true
  defp empty_or_nil?(_), do: false

  @doc """
  Cleans tool schemas by removing fields that some providers reject.
  Removes: $id, $schema, additionalProperties, strict
  """
  def clean_tool_schemas(request) do
    tools = request["tools"]

    if is_list(tools) and length(tools) > 0 do
      cleaned = Enum.map(tools, &clean_single_tool/1)
      Map.put(request, "tools", cleaned)
    else
      request
    end
  end

  defp clean_single_tool(%{"function" => func} = tool) do
    cleaned_func =
      func
      |> Map.delete("strict")
      |> update_in_if_exists(["parameters"], &clean_json_schema/1)

    Map.put(tool, "function", cleaned_func)
  end

  defp clean_single_tool(tool), do: tool

  defp clean_json_schema(schema) when is_map(schema) do
    schema
    |> Map.delete("$id")
    |> Map.delete("$schema")
    |> Map.delete("additionalProperties")
    |> update_in_if_exists(["properties"], fn props ->
      Map.new(props, fn {k, v} -> {k, clean_json_schema(v)} end)
    end)
    |> update_in_if_exists(["items"], &clean_json_schema/1)
  end

  defp clean_json_schema(other), do: other

  defp update_in_if_exists(map, keys, func) do
    case get_in(map, keys) do
      nil -> map
      val -> put_in(map, keys, func.(val))
    end
  end

  @doc """
  Removes `strict` field from tool definitions.
  """
  def remove_strict_from_tools(request) do
    tools = request["tools"]

    if is_list(tools) and length(tools) > 0 do
      cleaned =
        Enum.map(tools, fn tool ->
          case tool do
            %{"function" => func} ->
              Map.put(tool, "function", Map.delete(func, "strict"))

            _ ->
              tool
          end
        end)

      Map.put(request, "tools", cleaned)
    else
      request
    end
  end

  @doc """
  Clamps temperature to a specific range.
  """
  def clamp_temperature(request, min_val, max_val) do
    case request["temperature"] do
      nil ->
        request

      temp when is_number(temp) ->
        clamped = temp |> max(min_val) |> min(max_val)
        Map.put(request, "temperature", clamped)

      _ ->
        request
    end
  end

  @doc """
  Fixes finish_reason for tool calls (some providers return empty string).
  """
  def fix_tool_call_finish_reason(response) do
    case response do
      %{"choices" => choices} when is_list(choices) ->
        fixed =
          Enum.map(choices, fn choice ->
            has_tools =
              case choice do
                %{"message" => %{"tool_calls" => calls}} when is_list(calls) and calls != [] ->
                  true

                _ ->
                  false
              end

            if has_tools and choice["finish_reason"] in [nil, ""] do
              Map.put(choice, "finish_reason", "tool_calls")
            else
              choice
            end
          end)

        Map.put(response, "choices", fixed)

      _ ->
        response
    end
  end

  # ── Reasoning effort injection ────────────────────────────────────────────
  #
  # Step-level `reasoning_effort` is an opt-in default. Adapters call this with
  # the provider-specific `format` so the same canonical level ("high",
  # "xhigh", ...) is translated into whatever field the upstream API expects.
  #
  # Precedence rules:
  #   1. A nil/"" effort means "leave the request untouched" — the provider's
  #      own defaults (or a client-supplied value) apply.
  #   2. If the body already carries the relevant field (e.g. the client sent
  #      `reasoning_effort` or `thinking`), that value wins and the step
  #      default is *not* applied.

  # Anthropic extended-thinking budget_tokens mapped per effort level.
  @anthropic_thinking_budget %{
    "minimal" => 1_024,
    "low" => 4_096,
    "medium" => 10_000,
    "high" => 16_000,
    "xhigh" => 24_000,
    "max" => 32_000
  }

  # Gemini thinkingBudget mapped per effort level (Gemini 2.5 accepts 0..24576).
  @gemini_thinking_budget %{
    "minimal" => 0,
    "low" => 2_048,
    "medium" => 8_192,
    "high" => 16_384,
    "xhigh" => 24_576,
    "max" => 24_576
  }

  @doc """
  Injects a step-level reasoning effort default into an upstream request body.

  `format` selects how the canonical effort level is rendered for a provider:

    * `:openai`     — sets top-level `reasoning_effort` (OpenAI, xAI, …)
    * `:on_off`     — sets `thinking: %{"type" => "enabled"}` (DeepSeek, z.ai,
                      Moonshot-style providers that only accept on/off)
    * `:anthropic`  — sets `thinking: %{"type" => "enabled", "budget_tokens" => n}`
                      and guarantees `max_tokens` exceeds the budget
    * `:gemini`     — sets `generationConfig.thinkingConfig.thinkingBudget`
    * `:responses`  — sets `reasoning: %{"effort" => level}` (Responses API)
    * `:none`       — no-op

  For `:openai` and `:responses` the effort string is forwarded verbatim —
  never clamped or rewritten. `"none"` is treated as an explicit disable where
  the provider only distinguishes on/off (it sets
  `thinking: %{"type" => "disabled"}`).
  """
  def inject_reasoning_effort(body, effort, format)

  def inject_reasoning_effort(body, nil, _format), do: body
  def inject_reasoning_effort(body, "", _format), do: body
  def inject_reasoning_effort(body, _effort, :none), do: body

  # OpenAI-style: top-level `reasoning_effort`. The configured value is sent
  # verbatim — no clamping or rewriting. Which levels a model accepts is the
  # step author's choice (the UI offers the model's supported set from
  # models.dev when known); an unsupported level surfaces as a provider error
  # in the logs rather than being silently downgraded.
  def inject_reasoning_effort(body, effort, :openai) do
    if Map.has_key?(body, "reasoning_effort") do
      body
    else
      Map.put(body, "reasoning_effort", effort)
    end
  end

  # On/off providers (DeepSeek, z.ai, Moonshot-style). Only the presence of
  # reasoning matters, not the level.
  def inject_reasoning_effort(body, effort, :on_off) do
    cond do
      Map.has_key?(body, "thinking") ->
        body

      effort == "none" ->
        Map.put(body, "thinking", %{"type" => "disabled"})

      true ->
        Map.put(body, "thinking", %{"type" => "enabled"})
    end
  end

  # Anthropic extended thinking with a token budget.
  def inject_reasoning_effort(body, "none", :anthropic) do
    if Map.has_key?(body, "thinking"), do: Map.delete(body, "thinking"), else: body
  end

  def inject_reasoning_effort(body, effort, :anthropic) do
    if Map.has_key?(body, "thinking") do
      body
    else
      case Map.get(@anthropic_thinking_budget, effort) do
        nil ->
          body

        budget ->
          # Anthropic requires max_tokens > budget_tokens. Bump max_tokens so
          # there's still headroom for the actual completion.
          body
          |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
          |> ensure_anthropic_max_tokens(budget)
      end
    end
  end

  # Google Gemini thinkingConfig.
  def inject_reasoning_effort(body, "none", :gemini) do
    put_gemini_thinking(body, 0)
  end

  def inject_reasoning_effort(body, effort, :gemini) do
    case Map.get(@gemini_thinking_budget, effort) do
      nil -> body
      budget -> put_gemini_thinking(body, budget)
    end
  end

  # OpenAI Responses API (Codex backend). `reasoning.effort`, sent verbatim —
  # same no-clamping policy as :openai above.
  def inject_reasoning_effort(body, effort, :responses) do
    if Map.has_key?(body, "reasoning") do
      body
    else
      Map.put(body, "reasoning", %{"effort" => effort})
    end
  end

  defp ensure_anthropic_max_tokens(body, budget) do
    # Reserve headroom for the visible completion after the thinking budget.
    min_completion = 4_096
    required = budget + min_completion

    case body["max_tokens"] do
      n when is_integer(n) and n > budget -> body
      _ -> Map.put(body, "max_tokens", required)
    end
  end

  defp put_gemini_thinking(body, budget) do
    gen_config = Map.get(body, "generationConfig", %{})
    thinking_config = Map.get(gen_config, "thinkingConfig", %{})

    # Respect a client-supplied thinkingBudget.
    if Map.has_key?(thinking_config, "thinkingBudget") do
      body
    else
      thinking_config = Map.put(thinking_config, "thinkingBudget", budget)
      gen_config = Map.put(gen_config, "thinkingConfig", thinking_config)
      Map.put(body, "generationConfig", gen_config)
    end
  end
end
