defmodule DodoRouter.Proxy.Adapter do
  @moduledoc """
  Behaviour for LLM provider adapters.
  """

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
      String.contains?(message, "content") -> :content_policy
      String.contains?(message, "policy") -> :content_policy
      true -> :bad_request
    end
  end

  def categorize_error(status, _body) when status >= 500, do: :server_error
  def categorize_error(_status, _body), do: :unknown

  @doc """
  Determines if an error should trigger fallback to next provider.
  """
  def should_fallback?(:rate_limited), do: true
  def should_fallback?(:server_error), do: true
  def should_fallback?(:timeout), do: true
  def should_fallback?(:model_unavailable), do: true
  def should_fallback?(:auth_error), do: true
  def should_fallback?(:unknown), do: true
  def should_fallback?(_), do: false

  @doc """
  Extracts error message from response body.
  """
  def get_error_message(%{"error" => %{"message" => msg}}), do: String.downcase(msg)
  def get_error_message(%{"message" => msg}), do: String.downcase(msg)
  def get_error_message(_), do: ""

  @doc """
  Extracts usage from response.
  """
  def extract_usage(%{"usage" => usage}) do
    %{
      prompt_tokens: usage["prompt_tokens"],
      completion_tokens: usage["completion_tokens"],
      total_tokens: usage["total_tokens"]
    }
  end

  def extract_usage(_), do: %{prompt_tokens: nil, completion_tokens: nil, total_tokens: nil}

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
  # Everything else (router_slug, parallel_tool_calls, etc.) is stripped.
  @allowed_request_fields ~w(
    model messages temperature top_p max_tokens max_completion_tokens
    stream stream_options stop frequency_penalty presence_penalty
    tools tool_choice response_format seed n logprobs top_logprobs
    user reasoning_effort thinking
  )

  @doc """
  Strips non-standard fields from the incoming request body before
  forwarding to an upstream provider.

  Clients may send extra fields (e.g. `router_slug`, `parallel_tool_calls`)
  that are not part of the provider's API. This whitelist ensures only
  recognized fields are forwarded, preventing 400 Bad Request errors.
  """
  def sanitize_request(request) when is_map(request) do
    sanitized =
      request
      |> Map.take(@allowed_request_fields)
      |> normalize_max_completion_tokens()
      |> sanitize_messages()

    sanitized
  end

  def sanitize_request(request), do: request

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
          ~w(role content name tool_calls tool_call_id function_call reasoning_details reasoning_content)
        )
        |> normalize_message_content()
        |> migrate_function_call()
      end)

    Map.put(request, "messages", sanitized)
  end

  defp sanitize_messages(request), do: request

  # Normalize content from array format to string.
  # OpenAI-style: [{"type": "text", "text": "..."}] -> "..."
  # Only normalize for tool messages and when content is a list.
  defp normalize_message_content(%{"content" => content, "role" => role} = msg)
       when is_list(content) and role in ["tool", "user"] do
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

  @proxy_overrides ~w(authorization content-type)
                   |> Enum.map(&String.downcase/1)

  def build_forwarded_headers(client_headers, proxy_headers) when is_list(client_headers) do
    filtered =
      Enum.reject(client_headers, fn {key, _} ->
        String.downcase(key) in @proxy_overrides
      end)

    filtered ++ proxy_headers
  end

  def build_forwarded_headers(client_headers, proxy_headers) when is_nil(client_headers) do
    proxy_headers
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
end
