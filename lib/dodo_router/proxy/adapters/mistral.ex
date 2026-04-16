defmodule DodoRouter.Proxy.Adapters.Mistral do
  @moduledoc """
  Adapter for Mistral AI API.

  Supports Mistral Large, Small, and Codestral models.

  Transformations applied:
  - Strip `name` from non-tool messages (only tool messages support it)
  - Clean tool schemas (remove $id, $schema, additionalProperties, strict)
  - Filter empty assistant messages
  - Flatten content arrays to strings (for text-only content)
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

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.Adapters.OpenAICompatible
  alias DodoRouter.Routers.RoutingStep

  @base_url "https://api.mistral.ai/v1"

  @impl true
  def call(request, %RoutingStep{} = step, api_key) do
    request
    |> transform_request()
    |> OpenAICompatible.call(step, api_key, @base_url, provider: "mistral")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    request
    |> transform_request()
    |> OpenAICompatible.stream(step, api_key, send_chunk, @base_url, provider: "mistral")
  end

  defp transform_request(request) do
    request
    |> Adapter.strip_name_from_messages(:non_tool)
    |> Adapter.clean_tool_schemas()
    |> Adapter.filter_empty_assistant_messages()
    |> Adapter.flatten_content_to_string()
  end
end
