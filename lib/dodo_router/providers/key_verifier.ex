defmodule DodoRouter.Providers.KeyVerifier do
  @moduledoc """
  Cheapest safe active probe for a provider API key.

  Most providers accept an authenticated `GET /models`, which is free and
  proves the key authenticates. Two families are special:

  * `openai-codex` — the ChatGPT backend has no free listing endpoint, but a
    successful OAuth token refresh proves the credentials work.
  * `anthropic_oauth` — the scoped setup-token may 401 on /models even when
    valid, so there is no safe probe; it stays unverified until live traffic
    classifies it.

  A probe failure NEVER times out into "invalid": timeouts and 5xx are
  `:transient` (see `KeyHealth`).
  """

  alias DodoRouter.Providers
  alias DodoRouter.Providers.KeyHealth
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy.Adapter.Registry

  @receive_timeout 8_000

  @type outcome ::
          {:ok, :valid}
          | {:ok, :unverifiable}
          | {:error, :auth_invalid | :quota | :transient | :unknown, String.t() | nil}

  @spec verify(ProviderKey.t(), keyword()) :: outcome()
  def verify(%ProviderKey{} = key, req_opts \\ []) do
    case probe_style(key.provider_slug) do
      :skip_oauth_refresh -> verify_via_oauth_refresh(key)
      :skip -> {:ok, :unverifiable}
      style -> probe(style, key, req_opts)
    end
  end

  @doc false
  def probe_style("openai-codex"), do: :skip_oauth_refresh
  def probe_style("anthropic_oauth"), do: :skip
  def probe_style("anthropic"), do: :anthropic
  def probe_style("google"), do: :google
  def probe_style(_slug), do: :openai_compat

  defp verify_via_oauth_refresh(key) do
    raw = Providers.resolve_api_key(key)
    if raw, do: {:ok, :valid}, else: {:error, :auth_invalid, "OAuth token refresh failed"}
  end

  defp probe(style, key, req_opts) do
    api_key = Providers.resolve_api_key(key)
    base = Registry.endpoint_for(key.provider_slug)

    cond do
      is_nil(api_key) -> {:error, :unknown, "could not resolve key material"}
      is_nil(base) -> {:ok, :unverifiable}
      true -> request(style, base, api_key, req_opts)
    end
  end

  defp request(style, base, api_key, req_opts) do
    {url, headers, params} = probe_request(style, base, api_key)

    opts =
      [url: url, headers: headers, params: params, receive_timeout: @receive_timeout, retry: false]
      |> Keyword.merge(req_opts)

    case Req.get(opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        case KeyHealth.classify(status, nil, body) do
          :ok -> {:ok, :valid}
          class -> {:error, class, KeyHealth.error_detail(body)}
        end

      {:error, %{reason: :timeout}} ->
        {:error, :transient, "probe timed out"}

      {:error, err} ->
        {:error, :transient, KeyHealth.error_detail(inspect(err))}
    end
  end

  defp probe_request(:anthropic, base, api_key) do
    {models_url(base), [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}], []}
  end

  defp probe_request(:google, base, api_key) do
    {models_url(base), [], [key: api_key]}
  end

  defp probe_request(:openai_compat, base, api_key) do
    {models_url(base), [{"authorization", "Bearer " <> api_key}], []}
  end

  defp models_url(base) do
    String.trim_trailing(base, "/") <> "/models"
  end
end
