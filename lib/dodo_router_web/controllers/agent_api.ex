defmodule DodoRouterWeb.AgentApi do
  @moduledoc """
  Shared shapes for the agent-facing JSON API under `/r/:router_slug`.

  These endpoints authenticate with a router's API key — the same credential
  the product already holds to make proxy calls — so a coding agent working on
  that product needs no second credential and no browser session. What the key
  can reach is scoped to its own router: a key handed to one product must not
  enumerate another product's traffic or evaluations.

  Everything here is written for a reader that cannot see the UI. Errors name
  the guide, ids that point at a fuller record are always included, and money
  is a plain JSON number so a caller can sort by it without parsing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias DodoRouter.Agents.Principal

  @max_limit 100
  @default_limit 20

  @doc """
  The user behind the authenticated agent credential.
  """
  def current_user(conn), do: principal(conn).user

  def principal(conn), do: conn.assigns.agent_principal

  @doc """
  Whether this credential may read prompt and response text.

  Callers must use this to *mark* what they withheld rather than quietly
  omitting it — a field that vanishes without explanation is the same failure
  as a silently dropped request field, and an agent has no way to tell
  "there was nothing there" from "you may not see it".
  """
  def may_read_bodies?(conn), do: Principal.allows?(principal(conn), "logs:read_bodies")

  @doc """
  Either the value, or a marker naming the scope that would have shown it.
  """
  def body_or_marker(conn, value) do
    if may_read_bodies?(conn),
      do: value,
      else: %{withheld: "requires the logs:read_bodies scope"}
  end

  @doc """
  Where an agent that got something wrong can read what to do instead.

  Falls back to the unscoped entry point when the failure happened before a
  router was resolved — pointing a program at a browser page would be no help
  at all, and a 401 is exactly when the caller needs somewhere to go.
  """
  def guide_url(conn) do
    case conn.path_params["router_slug"] do
      nil -> "#{DodoRouterWeb.Endpoint.url()}/agent"
      slug -> "#{DodoRouterWeb.Endpoint.url()}/r/#{slug}/agent"
    end
  end

  def router_slug(conn), do: conn.assigns.current_router.slug

  @doc """
  A JSON error carrying a pointer back to the guide.

  A 404 that only says "not found" costs an agent a round of guessing; one
  that names the endpoint describing the whole surface does not.
  """
  def error(conn, status, message, type \\ "invalid_request_error", extra \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{
      error: Map.merge(%{message: message, type: type}, extra),
      see: guide_url(conn)
    })
    |> halt()
  end

  @doc """
  `limit`/`offset` from query params, clamped so one call can't ask for the
  whole table.
  """
  def paging(params) do
    {
      params |> integer_param("limit", @default_limit) |> max(1) |> min(@max_limit),
      params |> integer_param("offset", 0) |> max(0)
    }
  end

  def integer_param(params, key, default) do
    case params[key] do
      nil -> default
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> elem_or(default)
      _ -> default
    end
  end

  defp elem_or({int, _rest}, _default), do: int
  defp elem_or(:error, default), do: default

  @doc """
  Casts an id param, so a malformed one is a 404 rather than a 500 from Ecto.
  """
  def uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  def uuid(_value), do: :error

  @doc "Decimal money as a JSON number, so a caller can sort on it directly."
  def money(nil), do: nil
  def money(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  def money(value) when is_number(value), do: value

  @doc """
  Long free text, capped with a visible marker.

  Silently halving a model's answer would make an agent reason about a
  response nobody produced; the marker plus the id of the full record is the
  honest version.
  """
  def truncate(nil, _max), do: nil

  def truncate(text, max) when is_binary(text) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "… [truncated, fetch the linked log for the full text]"
    end
  end

  @doc """
  Decodes a stored body for display, falling back to the raw string.

  Bodies are stored as text and may be truncated by the proxy, so a decode
  failure is expected rather than exceptional.
  """
  def maybe_json(nil), do: nil

  def maybe_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  @doc """
  Human-readable form of a `Replays.replay_blocker/1` reason.

  An evaluation whose source log can't be replayed fails at benchmark time,
  minutes after it was created — naming the reason at list time is what lets
  an agent pick a different log instead.
  """
  def blocker_reason(nil), do: nil
  def blocker_reason(:invalid_request_body), do: "stored request body is not valid JSON"
  def blocker_reason(:missing_messages), do: "stored request body has no messages"
  def blocker_reason(:truncated), do: "stored request body was truncated for storage"
  def blocker_reason(:log_not_persisted), do: "request was not persisted"
  def blocker_reason(other), do: to_string(other)
end
