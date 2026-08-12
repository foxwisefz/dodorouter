defmodule DodoRouter.Agents.AgentToken do
  @moduledoc """
  A scoped credential for the agent surface.

  Deliberately not the router's proxy API key. That key authenticates sending
  traffic; if it also authorises reading traffic back, a leaked `.env` stops
  being "someone burns my tokens" and becomes "someone has every prompt my
  product ever sent". These are separately issued, separately scoped and
  separately revocable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DodoRouter.Agents.Scopes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @prefix "dodo_agt_"

  schema "agent_tokens" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :token_prefix, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    # Only ever populated in memory, on the one response that mints it.
    field :token, :string, virtual: true, redact: true

    belongs_to :user, DodoRouter.Accounts.User
    belongs_to :router, DodoRouter.Routers.Router

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a new token. `user_id` is set by the caller, never cast.
  """
  def create_changeset(attrs, user_id) do
    {token, hash, prefix} = generate()

    %__MODULE__{}
    |> cast(attrs, [:name, :scopes, :expires_at, :router_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_scopes()
    |> validate_expiry()
    |> put_change(:user_id, user_id)
    |> put_change(:token_hash, hash)
    |> put_change(:token_prefix, prefix)
    |> put_change(:token, token)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:router_id)
  end

  defp validate_scopes(changeset) do
    changeset
    |> validate_change(:scopes, fn :scopes, scopes ->
      case Enum.reject(scopes, &Scopes.valid?/1) do
        [] -> []
        unknown -> [scopes: "unknown scopes: #{Enum.join(unknown, ", ")}"]
      end
    end)
    |> validate_length(:scopes, min: 1, message: "pick at least one")
  end

  # An expiry in the past would mint a credential that is dead on arrival —
  # confusing rather than safe, because the user believes they have one.
  defp validate_expiry(changeset) do
    validate_change(changeset, :expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
        do: [],
        else: [expires_at: "must be in the future"]
    end)
  end

  @doc """
  Whether this token may be used right now, and why not when it may not.

  Revocation and expiry are reported separately because they mean different
  things to whoever is reading the error: one is "someone took this away",
  the other is "this aged out and you can mint another".
  """
  def usable(%__MODULE__{revoked_at: %DateTime{}}), do: {:error, :revoked}

  def usable(%__MODULE__{expires_at: %DateTime{} = expires_at} = token) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: {:ok, token},
      else: {:error, :expired}
  end

  def usable(%__MODULE__{} = token), do: {:ok, token}

  @doc """
  Mints a token: the value shown once, its peppered hash, and a display prefix.

  Same construction as `Routers.Router.generate_api_key/0` — a SHA-256 hash
  peppered from `secret_key_base`, so the database never holds anything that
  can be replayed against the API.
  """
  def generate do
    random = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    token = @prefix <> random

    {token, hash_token(token), String.slice(token, 0, 16)}
  end

  def hash_token(token) do
    :crypto.hash(:sha256, token <> pepper()) |> Base.encode64()
  end

  def prefix, do: @prefix

  defp pepper do
    secret =
      Application.fetch_env!(:dodo_router, DodoRouterWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.hash(:sha256, secret <> "agent_token_pepper")
    |> binary_part(0, 32)
    |> Base.encode64()
  end
end
