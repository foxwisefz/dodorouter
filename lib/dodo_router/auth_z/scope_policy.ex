defmodule DodoRouter.AuthZ.ScopePolicy do
  @moduledoc """
  Which scopes a client may be granted (RFC 6749 §3.3).

  The catalog is `DodoRouter.Agents.Scopes` — the same names the bearer agent
  tokens use, so a scope means one thing regardless of which credential
  carried it. `AttestoMCP.Scopes` offers a generic `mcp:tools:call` vocabulary
  and is explicitly only a convention; adopting it would have given us two
  scope languages for one authorization model.
  """

  @behaviour AttestoPhoenix.ScopePolicy

  alias DodoRouter.Agents.Scopes

  # OIDC scopes attesto and clients expect to exist. They carry no access to
  # anything on the agent surface.
  @identity_scopes ~w(openid profile email offline_access)

  @impl true
  def authorize_scope(_client, requested) when is_list(requested) do
    {known, unknown} = Enum.split_with(requested, &known?/1)

    cond do
      unknown != [] ->
        # Narrowing silently would hand back a token that looks like it can do
        # what was asked and cannot. A typo should fail loudly at the
        # authorization endpoint, not at the first tool call.
        {:error, :invalid_scope}

      known == [] ->
        {:error, :invalid_scope}

      true ->
        {:ok, known}
    end
  end

  def authorize_scope(_client, _requested), do: {:error, :invalid_scope}

  defp known?(scope), do: Scopes.valid?(scope) or scope in @identity_scopes
end
