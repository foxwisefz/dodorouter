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
              {:ok, response()} | {:error, error_reason(), details :: map()}

  @callback stream(
              request(),
              RoutingStep.t(),
              api_key :: String.t(),
              send_chunk :: (binary() -> :ok),
              client_headers :: list()
            ) ::
              {:ok, response()} | {:error, error_reason(), details :: map()}

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

  @proxy_overrides ~w(authorization content-type)
                   |> Enum.map(&String.downcase/1)

  def build_forwarded_headers(client_headers, proxy_headers) do
    filtered =
      Enum.reject(client_headers, fn {key, _} ->
        String.downcase(key) in @proxy_overrides
      end)

    filtered ++ proxy_headers
  end
end
