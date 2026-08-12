defmodule DodoRouterWeb.Plugs.AgentAuth do
  @moduledoc """
  Authenticates the agent surface with a scoped agent token.

  Explicitly *not* `Plugs.ApiAuth`. That plug authenticates a router's proxy
  key, which exists to send traffic; this surface reads traffic back, and the
  two deserve credentials with different blast radii.

  Challenges are emitted as RFC 6750 `WWW-Authenticate` headers — `Bearer` on
  401, `error="insufficient_scope"` with the required scopes on 403. That is
  the shape MCP's authorization spec expects, so an OAuth resource server can
  later be swapped in behind `Principal` without changing how failures look
  to a client.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias DodoRouter.Agents
  alias DodoRouter.Agents.Principal
  alias DodoRouter.Routers

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw} <- bearer_token(conn),
         {:ok, principal} <- Agents.authenticate(raw),
         {:ok, conn} <- assign_router(conn, principal) do
      assign(conn, :agent_principal, principal)
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  @doc """
  Requires scopes for an action, as a controller plug:

      plug :require_scopes, ["logs:read"] when action in [:index, :show]

  Kept as a function plug rather than folded into `call/2` because which
  scopes an operation needs is a property of the operation, and putting it
  next to the action is what stops a new action from silently inheriting
  whatever the last one required.
  """
  def require_scopes(conn, required) do
    principal = conn.assigns[:agent_principal]
    required = List.wrap(required)

    cond do
      is_nil(principal) -> deny(conn, :invalid)
      Principal.allows?(principal, required) -> conn
      true -> deny(conn, {:insufficient_scope, required})
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case String.trim(token) do
          "" -> {:error, :missing}
          token -> {:ok, token}
        end

      _ ->
        {:error, :missing}
    end
  end

  # The router named in the path has to be one this credential may act on.
  # Endpoints that aren't router-scoped (the token's own metadata) pass through.
  defp assign_router(conn, principal) do
    case conn.path_params["router_slug"] do
      nil ->
        {:ok, conn}

      slug ->
        case Routers.get_router_by_slug(slug) do
          %{} = router ->
            if Principal.allows_router?(principal, router),
              do: {:ok, assign(conn, :current_router, router)},
              else: {:error, :no_such_router}

          nil ->
            {:error, :no_such_router}
        end
    end
  end

  defp deny(conn, reason) do
    {status, body, challenge} = denial(reason)

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_status(status)
    |> json(Map.put(body, :see, guide_url(conn)))
    |> halt()
  end

  defp denial(:missing),
    do:
      {401,
       error_body("Missing agent token. Send 'Authorization: Bearer <token>'.", "unauthorized"),
       ~s(Bearer realm="dodo-agent")}

  # A revoked or expired token names its own reason: the holder is the owner,
  # and "invalid" would send them hunting for a typo instead of minting a new
  # one. A token that never existed stays vague — that one may not be theirs.
  defp denial(:expired),
    do:
      {401, error_body("This agent token has expired. Mint a new one.", "unauthorized"),
       ~s(Bearer realm="dodo-agent", error="invalid_token")}

  defp denial(:revoked),
    do:
      {401, error_body("This agent token was revoked.", "unauthorized"),
       ~s(Bearer realm="dodo-agent", error="invalid_token")}

  defp denial(:invalid),
    do:
      {401, error_body("Invalid agent token.", "unauthorized"),
       ~s(Bearer realm="dodo-agent", error="invalid_token")}

  # 404, not 403: a token that may not touch this router should not be able to
  # discover that it exists.
  defp denial(:no_such_router),
    do:
      {404, error_body("No such router for this token.", "not_found"),
       ~s(Bearer realm="dodo-agent")}

  defp denial({:insufficient_scope, required}) do
    scope = Enum.join(required, " ")

    {403,
     error_body(
       "This token is missing the #{scope} scope.",
       "insufficient_scope"
     )
     |> put_in([:error, :required_scopes], required),
     ~s(Bearer realm="dodo-agent", error="insufficient_scope", scope="#{scope}")}
  end

  defp error_body(message, type), do: %{error: %{message: message, type: type}}

  defp guide_url(conn) do
    case conn.path_params["router_slug"] do
      nil -> "#{DodoRouterWeb.Endpoint.url()}/agent-tokens"
      slug -> "#{DodoRouterWeb.Endpoint.url()}/r/#{slug}/agent"
    end
  end
end
