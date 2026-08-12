defmodule DodoRouter.AuthZ.PrincipalStore do
  @moduledoc """
  Maps between an OAuth subject and a DodoRouter user.

  There is exactly one kind of resource owner here — a signed-in DodoRouter
  user — so the subject is that user's id, namespaced with the principal-kind
  prefix attesto requires at mint time.
  """

  @behaviour AttestoPhoenix.PrincipalStore

  alias DodoRouter.Accounts
  alias DodoRouter.Accounts.User

  # `Attesto.Token` rejects an unprefixed subject at mint time, so the kind is
  # part of the identifier rather than an assumption about it. Keeping the
  # prefix in one module is what stops "is this id a user or a client?" from
  # becoming a guess later.
  @prefix "user:"

  @impl true
  def load_principal(@prefix <> user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> fetch(uuid)
      :error -> {:error, :not_found}
    end
  end

  def load_principal(_subject), do: {:error, :not_found}

  @impl true
  def build_principal(_client, subject_id, _scope) do
    user_id = String.replace_prefix(subject_id, @prefix, "")

    case load_principal(@prefix <> user_id) do
      {:ok, %User{} = user} ->
        %{
          sub: @prefix <> user.id,
          email: user.email,
          # Not a claim a client should read as authorization — the scopes on
          # the token decide that. It is here so an operator reading a decoded
          # token can tell whose it is.
          name: user.email
        }

      {:error, :not_found} ->
        %{sub: @prefix <> user_id}
    end
  end

  @doc "The subject identifier for a user, for whoever needs to mint one."
  def subject_for(%User{id: id}), do: @prefix <> id

  def prefix, do: @prefix

  defp fetch(uuid) do
    {:ok, Accounts.get_user!(uuid)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
