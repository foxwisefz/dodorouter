defmodule DodoRouter.Proxy.Adapters.Mistral do
  @moduledoc """
  Adapter for Mistral AI API.

  Supports Mistral Large, Small, and Codestral models.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "mistral",
    display_name: "Mistral",
    key_slugs: ["mistral"],
    endpoints: %{
      "mistral" => "https://api.mistral.ai/v1"
    },
    models: ~w(mistral-large-latest mistral-small-latest codestral-latest),
    color: "orange",
    short_description: "Mistral Large, Small, Codestral"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.mistral.ai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "mistral")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "mistral")
  end
end
