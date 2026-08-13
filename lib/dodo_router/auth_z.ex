defmodule DodoRouter.AuthZ do
  @moduledoc """
  The authorization-server configuration, resolved once and cached.

  The plugs take `config: &DodoRouter.AuthZ.config/0` as a remote capture
  because they initialise at compile time, so this has to be a named function
  rather than a closure over application env.
  """

  alias DodoRouter.AuthZ.PrincipalStore

  @doc """
  The resource-server view of the config, for verifying presented tokens.

  Distinct from `server_config/0` on purpose: the two halves take different
  structs, and handing the authorization-server config to a verifying plug
  fails as a FunctionClauseError deep inside `Attesto.Token.verify/3` rather
  than anywhere that names the mistake.
  """
  def resource_config do
    case :persistent_term.get({__MODULE__, :resource_config}, nil) do
      nil ->
        config = AttestoPhoenix.Config.to_attesto_config(server_config())
        :persistent_term.put({__MODULE__, :resource_config}, config)
        config

      config ->
        config
    end
  end

  @doc "The `AttestoPhoenix.Config` this authorization server runs on."
  def server_config do
    case :persistent_term.get({__MODULE__, :config}, nil) do
      nil ->
        config =
          :dodo_router
          |> Application.get_env(AttestoPhoenix.Config, [])
          |> AttestoPhoenix.Config.new()

        :persistent_term.put({__MODULE__, :config}, config)
        config

      config ->
        config
    end
  end

  @doc """
  The principal kinds this server mints subjects for.

  Exactly one: a signed-in DodoRouter user. Attesto rejects an unprefixed or
  unknown-prefix `sub` at mint time, so this list and
  `DodoRouter.AuthZ.PrincipalStore`'s prefix have to agree — declared as a
  callback rather than a literal so config evaluation never has to call into a
  dependency.
  """
  def principal_kinds, do: [Attesto.PrincipalKind.new("user", PrincipalStore.prefix())]

  @doc false
  def reset_config do
    :persistent_term.erase({__MODULE__, :config})
    :persistent_term.erase({__MODULE__, :resource_config})
  end
end
