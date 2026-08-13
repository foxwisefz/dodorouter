defmodule DodoRouterWeb.Plugs.OAuthPrincipal do
  @moduledoc """
  Turns an attesto-verified access token into a `%DodoRouter.Agents.Principal{}`.

  Runs after `AttestoMCP.Plug.Authenticate`, which has already verified the
  signature, the audience (RFC 8707) and any sender constraint. All that is left
  is resolving the subject to a user and shaping the result the way every
  downstream reader already expects.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias DodoRouter.Agents.Principal
  alias DodoRouter.AuthZ.PrincipalStore

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:attesto_context] do
      %{subject: subject} = context when is_binary(subject) ->
        case PrincipalStore.load_principal(subject) do
          {:ok, user} ->
            assign(conn, :agent_principal, Principal.from_oauth(context, user))

          {:error, :not_found} ->
            # The token verified but names a user who no longer exists. Refusing
            # is the only honest answer: a deleted account must not keep acting
            # through a token minted before it went away.
            deny(conn, "This token's account no longer exists.")
        end

      _ ->
        deny(conn, "No verified access token on this request.")
    end
  end

  defp deny(conn, message) do
    conn
    |> put_status(401)
    |> json(%{error: %{message: message, type: "unauthorized"}})
    |> halt()
  end
end
