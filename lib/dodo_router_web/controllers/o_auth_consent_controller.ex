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
    granted = params |> Map.get("granted_scopes", []) |> List.wrap()

    # The granted set is what was ticked, not what was asked for. It replaces
    # `scope` before the binding is computed, so the single-use grant is bound
    # to the narrowed request — approving cannot later be redeemed for the
    # wider scope the client originally sent.
    authorize_params =
      params
      |> Map.drop(~w(decision _csrf_token granted_scopes))
      |> Map.put("scope", Enum.join(granted, " "))

    cond do
      granted == [] ->
        render_consent(conn, params, "Pick at least one permission, or refuse.")

      true ->
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

  def create(conn, params) do
    # A refusal has to go back to the client as access_denied rather than
    # leaving it waiting — re-entering without a grant lets attesto produce the
    # RFC 6749 §4.1.2.1 error on the redirect URI it already validated.
    query = params |> Map.drop(~w(decision _csrf_token granted_scopes)) |> URI.encode_query()
    redirect(conn, to: "/oauth/authorize?" <> query <> "&prompt=none")
  end

  defp render_consent(conn, params, error \\ nil) do
    client = load_client(params["client_id"])
    scopes = params |> Map.get("scope", "") |> String.split(" ", trim: true)

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
      scopes: Enum.map(scopes, &scope_detail/1),
      user: conn.assigns.current_scope.user,
      error: error,
      authorize_params: Map.drop(params, ~w(decision granted_scopes))
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
