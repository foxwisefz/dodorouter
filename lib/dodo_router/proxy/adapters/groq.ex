defmodule DodoRouter.Proxy.Adapters.Groq do
  @moduledoc """
  Adapter for Groq API.

  Ultra-fast inference for Llama models.

  Transformations applied:
  - Strip null values from assistant function_call fields
  - For streaming with response_format: falls back to non-streaming (Groq limitation)

  Note: Groq doesn't support response_format while streaming. If both are requested,
  we use non-streaming mode and return the full response.
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
    request
    |> transform_request()
    |> OpenAICompatible.call(step, api_key, @base_url, provider: "groq")
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk) do
    request = transform_request(request)

    # Groq doesn't support response_format + streaming together
    # Fall back to non-streaming and send full response as single chunk
    if needs_fake_stream?(request) do
      fake_stream(request, step, api_key, send_chunk)
    else
      OpenAICompatible.stream(request, step, api_key, send_chunk, @base_url, provider: "groq")
    end
  end

  @doc false
  def transform_request(request) do
    strip_null_function_calls(request)
  end

  @doc false
  # Remove null function_call from assistant messages
  @doc false
  def strip_null_function_calls(request) do
    messages = request["messages"] || []

    updated =
      Enum.map(messages, fn msg ->
        if msg["role"] == "assistant" and is_nil(msg["function_call"]) do
          Map.delete(msg, "function_call")
        else
          msg
        end
      end)

    Map.put(request, "messages", updated)
  end

  def needs_fake_stream?(request) do
    request["response_format"] != nil
  end

  # Fake streaming: make non-streaming call, send response as SSE chunk
  defp fake_stream(request, step, api_key, send_chunk) do
    case OpenAICompatible.call(request, step, api_key, @base_url, provider: "groq") do
      {:ok, response} ->
        # Send as SSE format
        send_chunk.("data: #{Jason.encode!(response)}\n\n")
        send_chunk.("data: [DONE]\n\n")
        {:ok, response}

      error ->
        error
    end
  end
end
