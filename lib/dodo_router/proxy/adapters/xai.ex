defmodule DodoRouter.Proxy.Adapters.XAI do
  @moduledoc """
  Adapter for xAI (Grok) API.

  Supports Grok 3 and Grok 3 Mini models.

  Transformations applied:
  - Strip `name` from all messages
  - Remove `strict` from tool definitions
  - Remove unsupported params (stop for grok-3-mini/grok-4, frequency_penalty for grok-4)
  - Fix empty finish_reason to "tool_calls" when tool_calls present
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "xai",
    display_name: "xAI",
    key_slugs: ["xai"],
    endpoints: %{
      "xai" => "https://api.x.ai/v1"
    },
    color: "slate",
    short_description: "Grok 3 models"

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.x.ai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    request
    |> transform_request(step.model)
    |> OpenAICompatible.call(step, api_key, @base_url,
      provider: "xai",
      reasoning_format: :openai,
      client_headers: client_headers
    )
    |> transform_response()
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    request
    |> transform_request(step.model)
    |> OpenAICompatible.stream(step, api_key, send_chunk, @base_url,
      provider: "xai",
      reasoning_format: :openai,
      client_headers: client_headers
    )
    |> transform_response()
  end

  @doc false
  def request_headers(api_key, client_headers),
    do: OpenAICompatible.build_headers(api_key, client_headers: client_headers)

  def transform_request(request, model) do
    request
    |> Adapter.strip_name_from_messages(:all)
    |> Adapter.remove_strict_from_tools()
    |> remove_unsupported_params(model)
  end

  defp remove_unsupported_params(request, model) do
    request
    |> maybe_remove_stop(model)
    |> maybe_remove_frequency_penalty(model)
  end

  defp maybe_remove_stop(request, model)
       when model in ["grok-3-mini", "grok-4", "grok-code-fast"] do
    Map.delete(request, "stop")
  end

  defp maybe_remove_stop(request, _model), do: request

  defp maybe_remove_frequency_penalty(request, model)
       when model in ["grok-4", "grok-code-fast"] do
    Map.delete(request, "frequency_penalty")
  end

  defp maybe_remove_frequency_penalty(request, _model), do: request

  @doc false
  def transform_response({:ok, response, meta}) do
    {:ok, Adapter.fix_tool_call_finish_reason(response), meta}
  end

  def transform_response(error), do: error
end
