defmodule DodoRouterWeb.OAuthConsentController do
  @moduledoc """
  The consent screen an assistant's authorization request lands on.

  This is the screen that justifies running an authorization server at all: the
  user is already signed in to DodoRouter, so approving an agent is one click
  and no secret is ever pasted into a config file.

  Approving mints a single-use grant bound to the exact request that was
  displayed — client, redirect, scopes and PKCE challenge — and re-enters
  `/oauth/authorize` carrying it. One Authorize click therefore cannot approve
  anything other than what was on screen.
  """

  use DodoRouterWeb, :controller

  alias AttestoPhoenix.ConsentGrant
  alias DodoRouter.AuthZ.{Client, PrincipalStore}
  alias DodoRouter.Agents.Scopes
  alias DodoRouter.Repo
  alias DodoRouter.Routers

  # Long enough to read the screen, short enough that an abandoned tab cannot
  # be completed by somebody else later.
  @grant_ttl_seconds 600

  plug :require_user

  def show(conn, params) do
    render_consent(conn, params)
  end

  def create(conn, %{"decision" => "approve"} = params) do
    user = conn.assigns.current_scope.user
    subject = PrincipalStore.subject_for(user)

    # The picker only ever adds router scopes itself, so any arriving through
    # the permission checkboxes is form tampering and is dropped.
    granted =
      params
      |> Map.get("granted_scopes", [])
      |> List.wrap()
      |> Enum.reject(&Scopes.router_scope?/1)

    # The granted set is what was ticked, not what was asked for. It replaces
    # `scope` before the binding is computed, so the single-use grant is bound
    # to the narrowed request — approving cannot later be redeemed for the
    # wider scope the client originally sent. Router narrowing rides the same
    # scope string, so it is bound and persisted the same way.
    cond do
      granted == [] ->
        render_consent(conn, params, "Pick at least one permission, or refuse.")

      true ->
        case granted_router_scopes(user, params) do
          {:error, message} ->
            render_consent(conn, params, message)

          {:ok, router_scopes} ->
            authorize_params =
              params
              |> Map.drop(~w(decision _csrf_token granted_scopes router_access granted_routers))
              |> Map.put("scope", Enum.join(granted ++ router_scopes, " "))

            binding = ConsentGrant.binding_from_params(authorize_params, subject)

            case consent_grant_store().mint(binding, @grant_ttl_seconds) do
              {:ok, token} ->
                query = authorize_params |> Map.put("consent_token", token) |> URI.encode_query()
                redirect(conn, to: "/oauth/authorize?" <> query)

              {:error, _reason} ->
                render_consent(conn, params, "Could not record that approval. Try again.")
            end
        end
    end
  end

  def create(conn, params) do
    # A refusal has to go back to the client as access_denied rather than
    # leaving it waiting — re-entering without a grant lets attesto produce the
    # RFC 6749 §4.1.2.1 error on the redirect URI it already validated.
    query =
      params
      |> Map.drop(~w(decision _csrf_token granted_scopes router_access granted_routers))
      |> URI.encode_query()

    redirect(conn, to: "/oauth/authorize?" <> query <> "&prompt=none")
  end

  # Which routers the approval reaches. "all" is the deliberate unbounded case
  # and adds no scope; "selected" grants one `router:<id>` scope per ticked
  # router. Ids are intersected with the user's own routers so a tampered form
  # cannot mint a grant naming somebody else's router — it would be refused at
  # every call anyway (`Principal.allows_router?/2` re-checks ownership), but a
  # grant that looks wider than it is would still be a lie on screen.
  defp granted_router_scopes(user, params) do
    case Map.get(params, "router_access", "all") do
      "selected" ->
        owned = Routers.list_routers(user) |> MapSet.new(& &1.id)

        selected =
          params
          |> Map.get("granted_routers", [])
          |> List.wrap()
          |> Enum.filter(&MapSet.member?(owned, &1))

        case selected do
          [] -> {:error, "Pick at least one router, or grant access to all of them."}
          ids -> {:ok, Enum.map(ids, &Scopes.router_scope/1)}
        end

      _all ->
        {:ok, []}
    end
  end

  defp render_consent(conn, params, error \\ nil) do
    client = load_client(params["client_id"])
    user = conn.assigns.current_scope.user

    requested = params |> Map.get("scope", "") |> String.split(" ", trim: true)

    # A client replaying a previous grant re-requests the router scopes it was
    # given. They are reach, not permissions — rendered as the picker's
    # preselection, never as permission rows.
    {router_scopes, permission_names} = Enum.split_with(requested, &Scopes.router_scope?/1)
    scopes = Enum.map(permission_names, &scope_detail/1)

    routers = Routers.list_routers(user)
    requested_router_ids = Scopes.router_ids(router_scopes)

    selected_router_ids =
      Enum.filter(requested_router_ids, fn id -> Enum.any?(routers, &(&1.id == id)) end)

    # Protocol scopes are not data access and must not sit at the same visual
    # weight as one. `openid` only asks for an identity assertion this API never
    # reads; `offline_access` decides whether the agent keeps working after the
    # token expires. Neither is a decision about your customers' prompts.
    {permissions, session} = Enum.split_with(scopes, &(&1.name not in ~w(openid offline_access)))

    conn
    # No app shell: the root layout boots app.js, which opens a LiveView socket
    # on a page that has no LiveView. An OAuth consent screen is a standalone
    # form — it should not depend on the application's JS at all, and letting it
    # do so produced a page-reload loop.
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:show,
      client: client,
      client_id: params["client_id"],
      scopes: permissions,
      session_scopes: session,
      routers: routers,
      selected_router_ids: selected_router_ids,
      user: user,
      error: error,
      authorize_params:
        Map.drop(params, ~w(decision granted_scopes router_access granted_routers))
    )
  end

  # A dynamically registered client picked its own name, so it is displayed as
  # a claim rather than a fact — an assistant could call itself anything.
  defp load_client(nil), do: nil
  defp load_client(client_id), do: Repo.get_by(Client, client_id: client_id)

  defp scope_detail(name) do
    case Scopes.get(name) do
      nil ->
        %{
          name: name,
          label: name,
          description: identity_scope_description(name),
          sensitive?: false
        }

      scope ->
        scope
    end
  end

  defp identity_scope_description("openid"), do: "Confirm which DodoRouter account you are."
  defp identity_scope_description("offline_access"), do: "Stay connected without asking again."
  defp identity_scope_description(_name), do: "No access to your traffic."

  defp require_user(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: %{}} ->
        conn

      _ ->
        conn
        |> put_session(:user_return_to, current_path(conn))
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  defp consent_grant_store,
    do: Application.get_env(:dodo_router, AttestoPhoenix.Config)[:consent_grant_store]
end
