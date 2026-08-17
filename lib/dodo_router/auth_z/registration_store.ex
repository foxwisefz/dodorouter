defmodule DodoRouter.AuthZ.RegistrationStore do
  @moduledoc """
  Dynamic Client Registration (RFC 7591 / RFC 7592).

  This is the callback that makes an assistant connector possible at all: a
  desktop agent cannot be pre-registered, because nobody knows its loopback
  callback port until it starts. It registers itself on first contact.

  Registering is deliberately *not* authorization. A client created here can
  ask for tokens, and gets none until a signed-in user completes consent — so
  an open registration endpoint grants an attacker nothing but a row.
  """

  @behaviour AttestoPhoenix.RegistrationStore

  alias DodoRouter.AuthZ.Client
  alias DodoRouter.Repo

  @impl true
  def register_client(attrs) when is_map(attrs) do
    # attesto issues the client_id and returns it in the RFC 7591 response, so
    # it has to be the one persisted. Generating our own here stored a row the
    # client could never be resolved by: registration returned 201 and then
    # /oauth/authorize rejected it as unknown.
    client_id = attrs["client_id"] || generate_client_id()
    public? = attrs["token_endpoint_auth_method"] in [nil, "none"]

    %Client{}
    |> Client.changeset(%{
      "client_id" => client_id,
      "client_name" => attrs["client_name"],
      "public" => public?,
      "redirect_uris" => attrs["redirect_uris"] || [],
      "grant_types" => attrs["grant_types"] || ["authorization_code", "refresh_token"],
      # Everything the client asserted, minus what we lifted into columns —
      # so a later question about what it claimed is answerable, and nothing
      # is silently dropped on the way in.
      "metadata" => Map.drop(attrs, ~w(client_id client_name redirect_uris grant_types)),
      "registration_access_token_hash" => nil
    })
    |> Repo.insert()
  end

  @impl true
  def unregister_client(%Client{} = client) do
    case Repo.delete(client) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def client_registration_access_token_hash(%Client{registration_access_token_hash: hash}),
    do: hash

  # Unprefixed per RFC 7591 §3.2.1 — the kind prefix is applied at mint time
  # in PrincipalStore.build_principal/3, which is the one place that owns it.
  defp generate_client_id,
    do: "dodo_client_" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))
end
