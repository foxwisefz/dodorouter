defmodule DodoRouter.Proxy.Adapters.Wafer do
  @moduledoc """
  Adapter for Wafer (Wafer Pass serverless API).

  Fully OpenAI-compatible surface at https://pass.wafer.ai/v1 serving open
  models (GLM, Kimi, MiniMax, Qwen). No request transformations are needed:
  Wafer strips unsupported sampling params per model server-side and inlines
  JSON Schema `$defs`/`definitions` references itself.

  Reasoning is controlled with a top-level `reasoning_effort`
  (none/low/medium/high/max), sent verbatim per the `:openai` format. Wafer
  also accepts `thinking: {"type": "enabled"|"disabled"}`, which forwards
  as the client sent it via the request-field allowlist.

  Streaming note: Wafer delivers tool_calls in a single chunk rather than
  argument-by-argument; the shared accumulator handles both shapes.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "wafer",
    display_name: "Wafer",
    key_slugs: ["wafer"],
    key_generation_url: "https://app.wafer.ai",
    endpoints: %{
      "wafer" => "https://pass.wafer.ai/v1"
    },
    color: "blue",
    short_description: "Open models (GLM, Kimi, MiniMax) on serverless inference"

  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://pass.wafer.ai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    OpenAICompatible.call(request, step, api_key, @base_url,
      provider: "wafer",
      reasoning_format: :openai,
      client_headers: client_headers
    )
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url,
      provider: "wafer",
      reasoning_format: :openai,
      client_headers: client_headers
    )
  end

  @doc false
  def request_headers(api_key, client_headers),
    do: OpenAICompatible.build_headers(api_key, client_headers: client_headers)
end
