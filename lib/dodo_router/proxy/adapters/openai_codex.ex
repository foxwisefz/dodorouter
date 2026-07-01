defmodule DodoRouter.Proxy.Adapters.OpenAICodex do
  @moduledoc """
  Adapter for OpenAI Codex (ChatGPT backend).

  Uses the ChatGPT subscription-based backend instead of the OpenAI Platform API.
  Credentials are obtained via OAuth device flow (see DodoRouter.OpenAICodexOAuth)
  or by pasting a bearer token manually.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "openai-codex",
    display_name: "OpenAI Codex",
    key_slugs: ["openai-codex"],
    endpoints: %{
      "openai-codex" => "https://chatgpt.com/backend-api/v1"
    },
    models: ~w(gpt-4o gpt-4o-mini o3 o3-mini gpt-4.1 gpt-4.1-mini),
    color: "emerald",
    short_description: "ChatGPT Plus/Pro subscription"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://chatgpt.com/backend-api/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, _client_headers \\ []) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "openai-codex")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, _client_headers \\ []) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url,
      provider: "openai-codex"
    )
  end
end
