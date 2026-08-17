defmodule DodoRouterWeb.Plugs.AttestoConfig do
  @moduledoc """
  Installs the authorization-server configuration on the connection.

  attesto's controllers read the config from `conn.private` rather than global
  state, so a host that forgets this plug gets a RuntimeError naming the key —
  which is how this was found, after the discovery documents 500'd.

  Both keys are required and they are different structs: the authorization
  server's own config, and the protocol-level config used to verify and mint.
  """

  import Plug.Conn

  alias DodoRouter.AuthZ

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_private(:attesto_phoenix_config, AuthZ.server_config())
    |> put_private(:attesto_protocol_config, AuthZ.resource_config())
  end
end
