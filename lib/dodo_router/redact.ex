defmodule DodoRouter.Redact do
  @moduledoc """
  Pattern-based secret redaction for logs and stored data.
  """

  @redacted "[REDACTED]"

  # Compiled regex patterns for common secrets
  @secret_patterns [
    # Bearer tokens
    ~r/Bearer\s+[A-Za-z0-9\-._~+\/]{10,}=*/i,
    # Basic auth
    ~r/Basic\s+[A-Za-z0-9+\/]{10,}={0,2}/i,
    # OpenAI / Anthropic sk- keys
    ~r/sk-[A-Za-z0-9\-_]{20,}/,
    # Generic API keys (key=value or key: value)
    ~r/(?:api[_-]?key)['\"]?\s*[:=]\s*['\"]?[^\s,'\"})\]{}>]{8,}/i,
    # JWTs (eyJ...)
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/,
    # AWS access key IDs
    ~r/(?:AKIA|ASIA)[0-9A-Z]{16}/,
    # Google API keys
    ~r/AIza[0-9A-Za-z\-_]{35}/,
    # Databricks tokens
    ~r/dapi[0-9a-f]{32}/,
    # GCP OAuth tokens
    ~r/\bya29\.[A-Za-z0-9_.~+\/-]+/
  ]

  @doc """
  Redact secrets from a string value using pattern matching.
  """
  def redact_secrets(value) when is_binary(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted)
    end)
  end

  def redact_secrets(value), do: value

  @doc """
  Redact headers - both by key name and by value patterns.
  """
  def redact_headers(nil), do: nil

  def redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, _} when k in ["authorization", "cookie", "set-cookie", "x-api-key"] ->
        {k, @redacted}

      {k, v} when is_binary(v) ->
        {k, redact_secrets(v)}

      other ->
        other
    end)
  end

  def redact_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn
      {k, _} when k in ["authorization", "cookie", "set-cookie", "x-api-key"] ->
        {k, @redacted}

      {k, [v | _]} when is_binary(v) ->
        {k, redact_secrets(v)}

      {k, v} when is_binary(v) ->
        {k, redact_secrets(v)}

      {k, v} ->
        {k, v}
    end)
  end
end
