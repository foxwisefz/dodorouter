defmodule DodoRouter.Proxy.Adapters.DeepSeek do
  @moduledoc """
  Adapter for DeepSeek API.

  Supports DeepSeek V3 (chat) and DeepSeek R1 (reasoner) models.

  Transformations applied:
  - Flatten content arrays to strings (doesn't support list format)
  - Normalize thinking param (only accepts {"type": "enabled"})
  - Map reasoning_effort to thinking enabled
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "deepseek",
    display_name: "DeepSeek",
    key_slugs: ["deepseek"],
    endpoints: %{
      "deepseek" => "https://api.deepseek.com/v1"
    },
    models: ~w(deepseek-chat deepseek-reasoner),
    color: "cyan",
    short_description: "DeepSeek V3, R1 models"

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.deepseek.com/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    request
    |> transform_request()
    |> OpenAICompatible.call(step, api_key, @base_url,
      provider: "deepseek",
      reasoning_format: :on_off,
      client_headers: client_headers
    )
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    request
    |> transform_request()
    |> OpenAICompatible.stream(step, api_key, send_chunk, @base_url,
      provider: "deepseek",
      reasoning_format: :on_off,
      supports_stream_options: false,
      client_headers: client_headers
    )
  end

  @doc false
  def transform_request(request) do
    request
    |> Adapter.flatten_content_to_string()
    |> normalize_thinking_param()
  end

  @doc false
  def normalize_thinking_param(request) do
    thinking = request["thinking"]
    reasoning_effort = request["reasoning_effort"]

    request = Map.delete(request, "reasoning_effort")

    cond do
      is_map(thinking) and thinking["type"] == "enabled" ->
        Map.put(request, "thinking", %{"type" => "enabled"})

      reasoning_effort not in [nil, "none"] ->
        Map.put(request, "thinking", %{"type" => "enabled"})

      true ->
        Map.delete(request, "thinking")
    end
  end
end
