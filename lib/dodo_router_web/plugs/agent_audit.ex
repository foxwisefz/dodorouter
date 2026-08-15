defmodule DodoRouterWeb.Plugs.AgentAudit do
  @moduledoc """
  Records every call against the agent surface, including refused ones.

  Placed *before* authentication in the pipeline and hooked into
  `register_before_send/2`, so the row is written whatever happens afterwards
  — a 401 from a token that never verified is as much a record as a
  successful read, and arguably more interesting.

  This mirrors how `Proxy.Fidelity` earns its coverage: recording lives in the
  path everything already goes through, rather than in each controller, because
  the alternative is a log populated by the two endpoints somebody remembered.
  """

  import Plug.Conn

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Principal

  @annotations :agent_audit_annotations

  def init(opts), do: opts

  def call(conn, opts) do
    started_at = System.monotonic_time(:millisecond)
    interface = Keyword.get(opts, :interface, "rest")

    conn
    |> put_private(@annotations, %{})
    |> register_before_send(&record(&1, interface, started_at))
  end

  @doc """
  Lets a controller add what only it knows: which record was touched, whether
  transcript text actually went out, and for MCP which tool ran.

  Everything else is derivable from the connection; these are not.
  """
  def annotate(conn, attrs) do
    current = conn.private[@annotations] || %{}
    put_private(conn, @annotations, Map.merge(current, Map.new(attrs)))
  end

  defp record(conn, interface, started_at) do
    annotations = conn.private[@annotations] || %{}
    principal = conn.assigns[:agent_principal]

    base = %{
      interface: interface,
      operation: "#{conn.method} #{conn.request_path}",
      outcome: outcome(conn.status),
      http_status: conn.status,
      remote_ip: remote_ip(conn),
      user_agent: header(conn, "user-agent"),
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      router_id: conn.assigns[:current_router] && conn.assigns.current_router.id
    }

    base
    |> Map.merge(principal_attrs(principal))
    |> Map.merge(annotations)
    |> Agents.record_call()

    conn
  end

  defp principal_attrs(%Principal{} = principal) do
    %{
      principal_kind: principal.kind,
      principal_name: principal.name,
      user_id: principal.user.id,
      scopes: principal.scopes
    }
  end

  # No principal means the credential never resolved. Recorded rather than
  # skipped: a run of these is someone probing the surface.
  defp principal_attrs(nil), do: %{principal_kind: "unauthenticated", scopes: []}

  defp outcome(status) when is_integer(status) and status < 400, do: "ok"
  defp outcome(status) when status in [401, 403], do: "denied"
  defp outcome(_status), do: "error"

  # Caddy *appends* the peer it observed to any X-Forwarded-For the caller
  # supplied, so the rightmost entry is the one our own edge vouched for and
  # the leftmost is whatever the client claimed. Taking the last is what stops
  # an audit row from recording an attacker-chosen address.
  defp remote_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [_ | _] = values ->
        values
        |> Enum.flat_map(&String.split(&1, ","))
        |> List.last()
        |> to_string()
        |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
