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
  def build_principal(_client, subject_id, scope) do
    user_id = String.replace_prefix(subject_id, @prefix, "")

    case load_principal(@prefix <> user_id) do
      {:ok, %User{} = user} ->
        %{
          # `kind` is required, not decorative: Attesto.Token.fetch_kind/2 looks
          # the principal kind up by this value and fails the whole mint with
          # :unknown_principal_kind when it is absent. It must match the kind
          # declared in DodoRouter.AuthZ.principal_kinds/0.
          kind: "user",
          # Like `kind`, `scopes` is required rather than optional: the mint
          # reads it off this map (Attesto.Token.normalize_scopes/1) and fails
          # the whole exchange with :invalid_scopes when it is missing. The
          # granted scope arrives as the third argument — this callback's job is
          # to carry it through, not to decide it. ScopePolicy already did that.
          scopes: normalize_scope(scope),
          sub: @prefix <> user.id,
          email: user.email,
          # Not a claim a client should read as authorization — the scopes on
          # the token decide that. It is here so an operator reading a decoded
          # token can tell whose it is.
          name: user.email
        }

      {:error, :not_found} ->
        %{kind: "user", scopes: normalize_scope(scope), sub: @prefix <> user_id}
    end
  end

  # Accepts either shape: attesto documents "the granted scope" without fixing
  # whether it arrives as a list or a space-delimited string, and guessing wrong
  # is a failed token exchange rather than a soft error.
  defp normalize_scope(scope) when is_list(scope), do: scope
  defp normalize_scope(scope) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp normalize_scope(_scope), do: []

  @doc "The subject identifier for a user, for whoever needs to mint one."
  def subject_for(%User{id: id}), do: @prefix <> id

  def prefix, do: @prefix

  defp fetch(uuid) do
    {:ok, Accounts.get_user!(uuid)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
