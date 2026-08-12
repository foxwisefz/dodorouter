defmodule DodoRouter.AuthZ.Client do
  @moduledoc """
  An OAuth client, almost always one that registered itself.

  A coding assistant cannot be pre-registered — nobody knows its callback port
  until it starts — so RFC 7591 dynamic registration is the normal path here
  and a hand-created client is the exception.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_clients" do
    field :client_id, :string
    field :client_name, :string
    field :public, :boolean, default: true
    field :client_secret_hash, :string, redact: true
    field :redirect_uris, {:array, :string}, default: []
    field :grant_types, {:array, :string}, default: []
    field :registration_access_token_hash, :string, redact: true
    field :metadata, :map, default: %{}

    belongs_to :registered_by, DodoRouter.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :client_id,
      :client_name,
      :public,
      :client_secret_hash,
      :redirect_uris,
      :grant_types,
      :registration_access_token_hash,
      :metadata,
      :registered_by_id
    ])
    |> validate_required([:client_id])
    |> validate_redirect_uris()
    |> unique_constraint(:client_id)
  end

  # Loopback HTTP is explicitly allowed for native apps (RFC 8252 §7.3) and is
  # exactly what a desktop agent uses; everything else must be HTTPS, or an
  # authorization code could be handed to a plaintext endpoint.
  defp validate_redirect_uris(changeset) do
    validate_change(changeset, :redirect_uris, fn :redirect_uris, uris ->
      case Enum.reject(uris, &acceptable_redirect?/1) do
        [] -> []
        bad -> [redirect_uris: "must be https or a loopback address: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  defp acceptable_redirect?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https"} -> true
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "[::1]", "localhost"] -> true
      # A private-use scheme (com.example.app:/callback) is the other shape
      # RFC 8252 blesses for native apps.
      %URI{scheme: scheme, host: nil} when is_binary(scheme) -> String.contains?(scheme, ".")
      _ -> false
    end
  end

  defp acceptable_redirect?(_uri), do: false
end
