defmodule DodoRouter.Proxy.Adapters.Cohere do
  @moduledoc """
  Adapter for Cohere API.

  Supports Command R and Command R+ models via OpenAI-compatible endpoint.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "cohere",
    display_name: "Cohere",
    key_slugs: ["cohere"],
    endpoints: %{
      "cohere" => "https://api.cohere.com/v2"
    },
    models: ~w(command-r-plus command-r),
    color: "coral",
    short_description: "Command R, R+ models"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.cohere.com/v2"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "cohere")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "cohere")
  end
end
