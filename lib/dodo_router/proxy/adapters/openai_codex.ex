defmodule DodoRouter.Proxy.Adapters.OpenAICodex do
  @moduledoc """
  Adapter for OpenAI Codex (ChatGPT backend).

  Uses the ChatGPT subscription-based backend instead of the OpenAI Platform API.
  Credentials are obtained via OAuth device flow (see DodoRouter.OpenAICodexOAuth)
  or by pasting a bearer token manually.

  The Codex backend uses the Responses API format upstream, so streaming and
  format conversion are handled by `DodoRouter.Proxy.Adapters.ResponsesAPI`.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "openai-codex",
    display_name: "OpenAI Codex",
    key_slugs: ["openai-codex"],
    endpoints: %{
      "openai-codex" => "https://chatgpt.com/backend-api/codex"
    },
    endpoint_path: "/responses",
    models: ~w(gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.2),
    color: "emerald",
    short_description: "ChatGPT Plus/Pro subscription"

  alias DodoRouter.Proxy.Adapters.ResponsesAPI
  alias DodoRouter.Routers.RoutingStep

  @endpoint "https://chatgpt.com/backend-api/codex/responses"

  @impl true
  def call(request, %RoutingStep{} = step, api_key, client_headers \\ []) do
    {token, extra_headers} = prepare_auth(api_key)

    ResponsesAPI.call(request, step, token, @endpoint,
      provider: "openai-codex",
      extra_headers: extra_headers,
      client_headers: client_headers
    )
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, client_headers \\ []) do
    {token, extra_headers} = prepare_auth(api_key)

    ResponsesAPI.stream(request, step, token, send_chunk, @endpoint,
      provider: "openai-codex",
      extra_headers: extra_headers,
      client_headers: client_headers
    )
  end

  @doc false
  def request_headers(api_key, client_headers) do
    {token, extra_headers} = prepare_auth(api_key)

    ResponsesAPI.build_headers(token,
      extra_headers: extra_headers,
      client_headers: client_headers
    )
  end

  @doc false
  def parse_credentials(api_key) do
    case Jason.decode(api_key) do
      {:ok, %{"access" => access, "account_id" => account_id}} ->
        {access, account_id}

      _ ->
        {api_key, nil}
    end
  end

  defp prepare_auth(api_key) do
    {token, account_id} = parse_credentials(api_key)

    extra_headers =
      if account_id do
        [{"ChatGPT-Account-Id", account_id}]
      else
        []
      end

    {token, extra_headers}
  end
end
