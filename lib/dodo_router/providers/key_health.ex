defmodule DodoRouter.Providers.KeyHealth do
  @moduledoc """
  Pure classification and status state machine for provider API key health.

  `classify/3` maps an upstream outcome (HTTP status + error reason + body)
  to a health class; `transition/2` decides how that class moves a key's
  stored status. No I/O — trivially unit-testable.

  Design rules:
  * A 2xx through the key is authoritative: it proves the key authenticates
    right now and heals any prior status (user may have rotated the secret).
  * 401/403 flip a key to invalid only when the body confirms an auth
    problem — a bare 401 can come from a gateway or proxy in front.
  * 5xx/timeouts are provider outages, never the key's fault.
  * A quota signal never rescues a confirmed-invalid key.
  """

  @auth_markers [
    "invalid_api_key",
    "invalid api key",
    "incorrect api key",
    "authentication_error",
    "invalid x-api-key",
    "api key expired",
    "revoked",
    "deactivated",
    "organization has been disabled",
    "account_deactivated",
    "permission_error",
    "token has expired"
  ]

  @quota_markers [
    "insufficient_quota",
    "insufficient credits",
    "billing",
    "credit balance",
    "quota exceeded",
    "exceeded your current quota",
    "payment required"
  ]

  @type class :: :ok | :auth_invalid | :quota | :rate_limit | :transient | :unknown

  @spec classify(integer() | nil, atom() | nil, term()) :: class()
  def classify(status, reason, body)

  def classify(status, _reason, _body) when is_integer(status) and status in 200..299, do: :ok

  def classify(status, _reason, body) when status in [401, 403] do
    if body_matches?(body, @auth_markers), do: :auth_invalid, else: :unknown
  end

  def classify(402, _reason, _body), do: :quota

  def classify(429, _reason, body) do
    if body_matches?(body, @quota_markers), do: :quota, else: :rate_limit
  end

  def classify(status, _reason, _body) when status == 408 or status in 500..599,
    do: :transient

  def classify(nil, reason, _body) when reason in [:timeout, :network_error, :closed],
    do: :transient

  def classify(_status, _reason, _body), do: :unknown

  @doc """
  Returns `{new_status, fields}` or `{:unchanged, fields}` where `fields`
  are the columns to write. `current` is the stored status string (nil means
  unverified).
  """
  @spec transition(String.t() | nil, class()) :: {String.t() | :unchanged, map()}
  def transition(_current, :ok) do
    now = DateTime.utc_now()

    {"valid",
     %{last_ok_at: now, last_error_class: nil, last_error_at: nil, last_error_detail: nil}}
  end

  def transition(_current, :auth_invalid), do: flip("invalid", :auth_invalid)

  def transition("invalid", :quota), do: record_only(:quota)
  def transition(_current, :quota), do: flip("quota_exceeded", :quota)

  def transition(_current, class) when class in [:rate_limit, :transient, :unknown],
    do: record_only(class)

  defp flip(status, class) do
    {status, error_fields(class)}
  end

  defp record_only(class) do
    {:unchanged, error_fields(class)}
  end

  defp error_fields(class) do
    %{last_error_class: to_string(class), last_error_at: DateTime.utc_now()}
  end

  @doc "Truncated human detail string for tooltips."
  def error_detail(body) when is_binary(body), do: String.slice(body, 0, 250)
  def error_detail(%{} = body), do: body |> inspect() |> String.slice(0, 250)
  def error_detail(_), do: nil

  defp body_matches?(nil, _markers), do: false

  defp body_matches?(body, markers) when is_map(body) do
    body |> inspect() |> body_matches?(markers)
  end

  defp body_matches?(body, markers) when is_binary(body) do
    down = String.downcase(body)
    Enum.any?(markers, &String.contains?(down, &1))
  end

  defp body_matches?(_body, _markers), do: false
end
