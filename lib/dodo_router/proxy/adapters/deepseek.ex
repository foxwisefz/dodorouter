defmodule DodoRouter.Proxy.Adapters.DeepSeek do
  @moduledoc """
  Adapter for DeepSeek API.

  Supports DeepSeek V3 (chat) and DeepSeek R1 (reasoner) models.
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

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.deepseek.com/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "deepseek")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "deepseek")
  end
end
