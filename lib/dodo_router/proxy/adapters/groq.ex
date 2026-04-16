defmodule DodoRouter.Proxy.Adapters.Groq do
  @moduledoc """
  Adapter for Groq API.

  Ultra-fast inference for Llama models.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "groq",
    display_name: "Groq",
    key_slugs: ["groq"],
    endpoints: %{
      "groq" => "https://api.groq.com/openai/v1"
    },
    models: ~w(llama-3.3-70b-versatile llama-3.1-8b-instant llama-4-scout-17b-16e-instruct llama-4-maverick-17b-128e-instruct),
    color: "purple",
    short_description: "Llama models with ultra-fast inference"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.groq.com/openai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    OpenAICompatible.call(request, step, api_key, @base_url, provider: "groq")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "groq")
  end
end
