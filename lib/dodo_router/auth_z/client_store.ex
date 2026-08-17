defmodule DodoRouter.AuthZ.ClientStore do
  @moduledoc """
  The OAuth client registry (RFC 6749 §2 / §3.1.2).

  attesto never owns this — it resolves a client through these callbacks and
  threads whatever we return back unchanged — so the registry, its secret
  hashing and its redirect policy are ours.
  """

  @behaviour AttestoPhoenix.ClientStore

  import Ecto.Query

  alias DodoRouter.AuthZ.Client
  alias DodoRouter.Repo

  @impl true
  def load_client(client_id) when is_binary(client_id) do
    case Repo.one(from c in Client, where: c.client_id == ^client_id) do
      nil -> {:error, :not_found}
      client -> {:ok, client}
    end
  end

  def load_client(_client_id), do: {:error, :not_found}

  @doc """
  Constant-time secret comparison.

  A public client has no secret and must not be able to authenticate by
  presenting one — otherwise "I know this client's id" quietly becomes "I am
  this client".
  """
  @impl true
  def verify_client_secret(%Client{public: true}, _presented), do: false
  def verify_client_secret(%Client{client_secret_hash: nil}, _presented), do: false

  def verify_client_secret(%Client{client_secret_hash: hash}, presented)
      when is_binary(presented) do
    Plug.Crypto.secure_compare(hash_secret(presented), hash)
  end

  def verify_client_secret(_client, _presented), do: false

  @impl true
  def client_id(%Client{client_id: client_id}), do: client_id

  @impl true
  def client_redirect_uris(%Client{redirect_uris: uris}), do: uris

  @impl true
  def client_public?(%Client{public: public}), do: public

  @doc """
  Whether this is a native app.

  Desktop agents redirect to a loopback address and cannot keep a secret.
  Declaring them native is what lets attesto apply the RFC 8252 rules — most
  importantly allowing the loopback port to vary, since the agent picks a free
  one at runtime and it will not be the one it registered with.
  """
  @impl true
  def client_native?(%Client{redirect_uris: uris}) do
    Enum.any?(uris, fn uri ->
      case URI.parse(uri) do
        %URI{scheme: "http", host: host} -> host in ["127.0.0.1", "[::1]", "localhost"]
        %URI{scheme: scheme, host: nil} when is_binary(scheme) -> String.contains?(scheme, ".")
        _ -> false
      end
    end)
  end

  @impl true
  def client_grant_types(%Client{grant_types: []}), do: ["authorization_code", "refresh_token"]
  def client_grant_types(%Client{grant_types: types}), do: types

  @doc """
  DPoP is offered but not demanded.

  Requiring it would refuse every client that does not implement it, and the
  point of this endpoint is that assistants can reach it. Sender-constraining
  is a per-client upgrade, not an entry requirement.
  """
  @impl true
  def client_requires_dpop?(%Client{metadata: metadata}), do: metadata["require_dpop"] == true

  @impl true
  def client_requires_mtls?(%Client{}), do: false

  @doc false
  def hash_secret(secret) when is_binary(secret),
    do: :crypto.hash(:sha256, secret) |> Base.encode64()
end
