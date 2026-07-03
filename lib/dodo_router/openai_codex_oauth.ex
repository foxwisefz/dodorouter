defmodule DodoRouter.OpenAICodexOAuth do
  @moduledoc """
  OpenAI ChatGPT/Codex OAuth device flow.

  This mirrors OpenCode's headless Codex flow:

    1. Request a device code from auth.openai.com.
    2. User opens https://auth.openai.com/codex/device and enters the code.
    3. Poll auth.openai.com for an authorization_code and code_verifier.
    4. Exchange those for access/refresh tokens using PKCE (no client secret).

  The resulting access token is for ChatGPT's Codex backend, not the OpenAI
  Platform API at api.openai.com.
  """

  alias DodoRouter.Providers.ProviderKey

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @issuer "https://auth.openai.com"
  @device_url @issuer <> "/api/accounts/deviceauth/usercode"
  @device_token_url @issuer <> "/api/accounts/deviceauth/token"
  @oauth_token_url @issuer <> "/oauth/token"
  @device_redirect_uri @issuer <> "/deviceauth/callback"
  @verification_uri @issuer <> "/codex/device"
  @account_claim "https://api.openai.com/auth"
  @refresh_margin_ms 60_000

  @doc """
  Starts the device authorization flow.
  """
  def start_device_authorization do
    case Req.post(@device_url,
           headers: json_headers(),
           json: %{client_id: @client_id},
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        with %{"device_auth_id" => device_auth_id, "user_code" => user_code} <- body do
          interval = body["interval"] |> parse_interval()

          {:ok,
           %{
             device_auth_id: device_auth_id,
             user_code: user_code,
             verification_uri: @verification_uri,
             interval: interval
           }}
        else
          _ -> {:error, :invalid_device_response}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Completes a device authorization flow after the user enters the code.

  Returns `{:pending, reason}` while the user has not completed authorization.
  """
  def complete_device_authorization(device_auth_id, user_code) do
    with {:ok, auth} <- poll_device_token(device_auth_id, user_code),
         {:ok, tokens} <- exchange_authorization_code(auth.authorization_code, auth.code_verifier) do
      {:ok, encode_credentials(tokens)}
    end
  end

  @doc """
  Returns a usable access token, refreshing and persisting credentials when needed.
  """
  def ensure_access_token(%ProviderKey{} = provider_key, raw_credentials) do
    ensure_access_token(provider_key, raw_credentials, &refresh_token/1)
  end

  @doc false
  def ensure_access_token(%ProviderKey{} = provider_key, raw_credentials, refresh_fun)
      when is_function(refresh_fun, 1) do
    case decode_credentials(raw_credentials) do
      {:ok, %{"access" => access} = credentials} ->
        if token_fresh?(credentials) do
          {:ok, access, credentials["account_id"]}
        else
          refresh_and_store(provider_key, credentials, refresh_fun)
        end

      {:error, _} ->
        # Allow a raw bearer token for manual debugging, but it cannot refresh.
        {:ok, raw_credentials, nil}
    end
  end

  def refresh_token(refresh_token) when is_binary(refresh_token) do
    body = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: @client_id
    }

    case Req.post(@oauth_token_url,
           headers: form_headers(),
           form: body,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, normalize_token_response(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def encode_credentials(tokens) do
    access = tokens["access_token"]
    refresh = tokens["refresh_token"]
    expires_in = tokens["expires_in"] || 3600
    account_id = extract_account_id(tokens)

    %{
      type: "openai_codex_oauth",
      access: access,
      refresh: refresh,
      expires: System.system_time(:millisecond) + expires_in * 1000,
      account_id: account_id
    }
    |> Jason.encode!()
  end

  def decode_credentials(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"type" => "openai_codex_oauth"} = credentials} -> {:ok, credentials}
      _ -> {:error, :invalid_credentials}
    end
  end

  def decode_credentials(_raw), do: {:error, :invalid_credentials}

  defp poll_device_token(device_auth_id, user_code) do
    case Req.post(@device_token_url,
           headers: json_headers(),
           json: %{device_auth_id: device_auth_id, user_code: user_code},
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        with %{"authorization_code" => code, "code_verifier" => verifier} <- body do
          {:ok, %{authorization_code: code, code_verifier: verifier}}
        else
          _ -> {:error, :invalid_device_token_response}
        end

      {:ok, %{status: status}} when status in [403, 404] ->
        {:pending, :authorization_pending}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange_authorization_code(code, verifier) do
    body = %{
      grant_type: "authorization_code",
      code: code,
      redirect_uri: @device_redirect_uri,
      client_id: @client_id,
      code_verifier: verifier
    }

    case Req.post(@oauth_token_url,
           headers: form_headers(),
           form: body,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, normalize_token_response(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_and_store(%ProviderKey{} = provider_key, %{"refresh" => refresh}, refresh_fun) do
    with {:ok, tokens} <- refresh_fun.(refresh),
         encoded <- encode_credentials(tokens),
         :ok <- DodoRouter.Providers.update_provider_key_secret(provider_key, encoded),
         {:ok, credentials} <- decode_credentials(encoded) do
      {:ok, credentials["access"], credentials["account_id"]}
    end
  end

  defp refresh_and_store(_provider_key, _credentials, _refresh_fun),
    do: {:error, :missing_refresh_token}

  defp token_fresh?(%{"expires" => expires}) when is_integer(expires) do
    expires > System.system_time(:millisecond) + @refresh_margin_ms
  end

  defp token_fresh?(_), do: false

  defp extract_account_id(tokens) do
    [tokens["id_token"], tokens["access_token"]]
    |> Enum.find_value(&extract_account_id_from_jwt/1)
  end

  defp extract_account_id_from_jwt(nil), do: nil

  defp extract_account_id_from_jwt(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      claims["chatgpt_account_id"] ||
        get_in(claims, [@account_claim, "chatgpt_account_id"]) ||
        get_in(claims, ["organizations", Access.at(0), "id"])
    else
      _ -> nil
    end
  end

  defp normalize_token_response(body) when is_map(body), do: body
  defp normalize_token_response(body) when is_binary(body), do: URI.decode_query(body)

  defp parse_interval(nil), do: 5
  defp parse_interval(interval) when is_integer(interval), do: max(interval, 1)

  defp parse_interval(interval) when is_binary(interval) do
    case Integer.parse(interval) do
      {value, _} -> max(value, 1)
      :error -> 5
    end
  end

  defp json_headers do
    [
      {"Content-Type", "application/json"},
      {"User-Agent", "dodo-router"}
    ]
  end

  defp form_headers do
    [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"User-Agent", "dodo-router"}
    ]
  end
end
