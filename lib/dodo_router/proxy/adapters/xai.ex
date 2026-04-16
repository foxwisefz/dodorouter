defmodule DodoRouter.Proxy.Adapters.XAI do
  @moduledoc """
  Adapter for xAI (Grok) API.

  Supports Grok 3 and Grok 3 Mini models.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "xai",
    display_name: "xAI",
    key_slugs: ["xai"],
    endpoints: %{
      "xai" => "https://api.x.ai/v1"
    },
    models: ~w(grok-3 grok-3-mini),
    color: "slate",
    short_description: "Grok 3 models"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.x.ai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "xai")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "xai")
  end
end
