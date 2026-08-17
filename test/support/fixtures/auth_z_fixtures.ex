defmodule DodoRouter.AuthZFixtures do
  @moduledoc """
  Mints real access tokens against the running configuration.

  Not `AttestoMCP.Test.Factory` — that mints for its own issuer, audience and
  `usr_123` subject, so a token from it proves nothing about whether *our*
  audience and principal kind line up. These go through the same
  `Attesto.Token.mint/3` the token endpoint uses.
  """

  alias DodoRouter.AuthZ
  alias DodoRouter.AuthZ.PrincipalStore
  alias DodoRouter.Agents.Scopes

  def access_token(user, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, Scopes.names())
    client_id = Keyword.get(opts, :client_id, "test-client")

    principal = %{
      sub: PrincipalStore.subject_for(user),
      kind: "user",
      scopes: scopes,
      claims: %{"client_id" => client_id}
    }

    {:ok, token} = Attesto.Token.mint(attesto_config(), principal, [])
    token.access_token
  end

  def attesto_config, do: AuthZ.resource_config()
end
