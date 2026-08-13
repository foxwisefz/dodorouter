defmodule DodoRouter.AuthZ.ConsentPolicy do
  @moduledoc """
  Who is authorizing, and whether they agreed (RFC 6749 §3.1 / §4.1.1).

  attesto mounts the authorization endpoint but never renders a login or
  consent screen — those are ours, and they run against the magic-link session
  the user already has. That is the whole point of running our own
  authorization server rather than delegating to a second identity system: the
  person approving is already signed in to DodoRouter.
  """

  @behaviour AttestoPhoenix.ConsentPolicy

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias AttestoPhoenix.ConsentGrant
  alias DodoRouter.AuthZ.PrincipalStore

  @impl true
  def authenticate_resource_owner(conn, _request, auth_opts) do
    user = current_user(conn)

    cond do
      user && not opt(auth_opts, :force_reauth, false) ->
        {:authenticated, %{subject: PrincipalStore.subject_for(user)}}

      # `prompt=none` means "do not show me any UI" — the honest answer when
      # nobody is signed in is to say interaction is required, not to redirect
      # into a login page the client asked us not to show.
      opt(auth_opts, :interactive, true) == false ->
        {:error, :login_required}

      true ->
        {:halt, to_login(conn)}
    end
  end

  # attesto passes the OIDC prompt/max_age directives as a map, not a keyword
  # list. Accepting both because the contract documents them loosely and a
  # wrong guess here is a 500 on the authorization endpoint, not a soft failure.
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(_opts, _key, default), do: default

  @impl true
  def consent(conn, request, subject) do
    subject_id = subject_id(subject)
    binding = ConsentGrant.binding(request, subject_id)

    case conn.params["consent_token"] do
      token when is_binary(token) and token != "" ->
        # Single-use and bound to this exact request, so one Authorize click
        # cannot approve a different client, redirect, scope set or PKCE
        # challenge than the one that was displayed.
        case consent_grant_store().consume(token, binding) do
          :ok -> {:consented, subject}
          {:error, _reason} -> {:halt, to_consent(conn)}
        end

      _ ->
        {:halt, to_consent(conn)}
    end
  end

  ## Redirects

  # Re-enter the authorization endpoint after login rather than dropping the
  # user on a dashboard: they arrived mid-flow and the client is waiting.
  defp to_login(conn) do
    conn
    |> put_session(:user_return_to, current_url(conn))
    |> redirect(to: "/users/log-in")
    |> halt()
  end

  defp to_consent(conn) do
    conn
    |> redirect(to: "/oauth/consent?" <> URI.encode_query(authorize_params(conn)))
    |> halt()
  end

  # Everything the authorization endpoint received, minus a stale consent
  # token, so the screen can rebuild the identical request when it re-enters.
  defp authorize_params(conn) do
    conn.params
    |> Map.drop(["consent_token"])
    |> Enum.filter(fn {_k, v} -> is_binary(v) end)
  end

  defp current_url(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{} = user} -> user
      _ -> nil
    end
  end

  defp subject_id(%{subject: subject}) when is_binary(subject), do: subject
  defp subject_id(%{"subject" => subject}) when is_binary(subject), do: subject
  defp subject_id(subject) when is_binary(subject), do: subject

  defp consent_grant_store,
    do: Application.get_env(:dodo_router, AttestoPhoenix.Config)[:consent_grant_store]
end
