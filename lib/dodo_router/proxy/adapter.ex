defmodule DodoRouter.Proxy.Adapter do
  @moduledoc """
  Behaviour for LLM provider adapters.
  """

  alias DodoRouter.Projects.RoutingStep

  @type request :: map()
  @type response :: map()
  @type error_reason :: :rate_limited | :server_error | :timeout | :model_unavailable | :bad_request | :auth_error | :content_policy | :unknown

  @callback call(request(), RoutingStep.t(), api_key :: String.t()) ::
              {:ok, response()} | {:error, error_reason(), details :: map()}

  @callback stream(request(), RoutingStep.t(), api_key :: String.t(), send_chunk :: (binary() -> :ok)) ::
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
end
