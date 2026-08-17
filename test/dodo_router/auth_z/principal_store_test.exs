defmodule DodoRouter.AuthZ.PrincipalStoreTest do
  @moduledoc """
  Tests the seam, not the function.

  `build_principal/3` returning a plausible-looking map proves nothing: what
  matters is whether `Attesto.Token.mint/3` accepts it. Two separate required
  keys were missing here in turn — `:kind` and `:scopes` — and each failed the
  token exchange with an opaque atom rather than anything naming the map.
  Asserting on the map's shape would have caught neither.
  """

  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.AuthZ
  alias DodoRouter.AuthZ.PrincipalStore

  defp mint(principal), do: Attesto.Token.mint(AuthZ.resource_config(), principal, [])

  describe "build_principal/3 output is mintable" do
    test "with the granted scope as a list" do
      user = AccountsFixtures.user_fixture()
      subject = PrincipalStore.subject_for(user)

      principal = PrincipalStore.build_principal(nil, subject, ["logs:read", "evals:read"])

      assert {:ok, token} = mint(principal)
      assert token.scope == "logs:read evals:read"
    end

    test "with the granted scope as a space-delimited string" do
      user = AccountsFixtures.user_fixture()
      subject = PrincipalStore.subject_for(user)

      # attesto documents "the granted scope" without fixing the shape.
      principal = PrincipalStore.build_principal(nil, subject, "logs:read logs:read_bodies")

      assert {:ok, token} = mint(principal)
      assert token.scope == "logs:read logs:read_bodies"
    end

    test "the minted token verifies, with our subject and audience" do
      user = AccountsFixtures.user_fixture()
      subject = PrincipalStore.subject_for(user)

      {:ok, token} = mint(PrincipalStore.build_principal(nil, subject, ["logs:read"]))

      assert {:ok, claims} = Attesto.Token.verify(AuthZ.resource_config(), token.access_token, [])
      assert claims["sub"] == subject
      assert claims["aud"] == AuthZ.resource_config().audience
    end

    test "a subject whose user is gone still mints, and resolves to nobody" do
      # The token endpoint must not 500 on a deleted account mid-flow; the
      # resource server refuses it later, where the refusal can be explained.
      principal =
        PrincipalStore.build_principal(nil, "user:#{Ecto.UUID.generate()}", ["logs:read"])

      assert {:ok, _token} = mint(principal)
      assert {:error, :not_found} = PrincipalStore.load_principal(principal.sub)
    end
  end

  describe "load_principal/1" do
    test "resolves a prefixed subject to its user" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, loaded} = PrincipalStore.load_principal(PrincipalStore.subject_for(user))
      assert loaded.id == user.id
    end

    test "refuses an unprefixed or malformed subject" do
      user = AccountsFixtures.user_fixture()

      # The prefix is what keeps "is this id a user or a client?" from being a
      # guess, so a bare uuid must not resolve.
      assert {:error, :not_found} = PrincipalStore.load_principal(user.id)
      assert {:error, :not_found} = PrincipalStore.load_principal("user:not-a-uuid")
      assert {:error, :not_found} = PrincipalStore.load_principal("client:#{user.id}")
    end
  end
end
