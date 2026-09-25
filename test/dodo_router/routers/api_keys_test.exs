defmodule DodoRouter.Routers.ApiKeysTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Accounts.Scope
  alias DodoRouter.Routers
  alias DodoRouterWeb.Plugs.ApiAuth
  import DodoRouter.AccountsFixtures
  import DodoRouter.RoutersFixtures
  import Plug.Conn

  setup do
    user = user_fixture()
    {router, original} = router_fixture(user)
    %{scope: Scope.for_user(user), router: router, original: original}
  end

  test "adding keys preserves the original and revocation affects only its target", ctx do
    assert {:ok, laptop, secret} =
             Routers.create_api_key(ctx.scope, ctx.router.id, %{name: "Laptop"})

    assert {:ok, ci, ci_secret} = Routers.create_api_key(ctx.scope, ctx.router.id, %{name: "CI"})
    assert String.starts_with?(secret, "sk-dodo-")
    refute laptop.api_key_hash == secret
    assert length(Routers.list_api_keys(ctx.scope, ctx.router.id)) == 3

    for key <- [ctx.original, secret, ci_secret] do
      assert Routers.get_router_by_api_key(key).id == ctx.router.id
    end

    assert {:ok, revoked} = Routers.revoke_api_key(ctx.scope, ctx.router.id, laptop.id)
    assert revoked.revoked_at
    assert is_nil(Routers.get_router_by_api_key(secret))
    assert Routers.get_router_by_api_key(ctx.original).id == ctx.router.id
    assert Routers.get_router_by_api_key(ci_secret).id == ctx.router.id
    assert Enum.any?(Routers.list_api_keys(ctx.scope, ctx.router.id), &(&1.id == ci.id))

    default = Enum.find(Routers.list_api_keys(ctx.scope, ctx.router.id), &(&1.name == "Default"))
    assert {:ok, _} = Routers.revoke_api_key(ctx.scope, ctx.router.id, default.id)
    assert is_nil(Routers.get_router_by_api_key(ctx.original))
  end

  test "key management is scoped to the owning user and router", ctx do
    other_scope = Scope.for_user(user_fixture())
    assert_raise Ecto.NoResultsError, fn -> Routers.list_api_keys(other_scope, ctx.router.id) end

    assert_raise Ecto.NoResultsError, fn ->
      Routers.create_api_key(other_scope, ctx.router.id, %{name: "Stolen"})
    end

    [key] = Routers.list_api_keys(ctx.scope, ctx.router.id)

    assert_raise Ecto.NoResultsError, fn ->
      Routers.revoke_api_key(other_scope, ctx.router.id, key.id)
    end

    {other_router, _} = router_fixture(ctx.scope.user)
    assert {:error, :not_found} = Routers.revoke_api_key(ctx.scope, other_router.id, key.id)
    assert Routers.get_router_by_api_key(ctx.original)
  end

  test "names are required and caller cannot override key ownership or secret", ctx do
    assert {:error, changeset} = Routers.create_api_key(ctx.scope, ctx.router.id, %{name: " "})
    assert errors_on(changeset).name

    assert {:error, _} =
             Routers.create_api_key(ctx.scope, ctx.router.id, %{name: String.duplicate("x", 101)})

    assert {:ok, key, secret} =
             Routers.create_api_key(ctx.scope, ctx.router.id, %{
               name: "Work",
               router_id: Ecto.UUID.generate(),
               api_key_hash: "chosen",
               revoked_at: DateTime.utc_now()
             })

    assert key.router_id == ctx.router.id
    assert is_nil(key.revoked_at)
    assert key.api_key_hash == Routers.Router.hash_api_key(secret)
  end

  test "API auth accepts multiple keys on both formats and legacy paths, enforces slug and revocation",
       ctx do
    {:ok, key, secret} = Routers.create_api_key(ctx.scope, ctx.router.id, %{name: "Client"})

    for token <- [ctx.original, secret], header <- ["authorization", "x-api-key"] do
      value = if header == "authorization", do: "Bearer " <> token, else: token

      for params <- [%{}, %{"router_slug" => ctx.router.slug}] do
        conn = Plug.Test.conn(:post, "/") |> put_req_header(header, value)
        conn = ApiAuth.call(%{conn | path_params: params}, [])
        assert conn.assigns.current_router.id == ctx.router.id
      end
    end

    conn = Plug.Test.conn(:post, "/") |> put_req_header("authorization", "Bearer " <> secret)

    assert ApiAuth.call(%{conn | path_params: %{"router_slug" => "wrong-router"}}, []).status ==
             401

    Routers.revoke_api_key(ctx.scope, ctx.router.id, key.id)
    assert ApiAuth.call(conn, []).status == 401
  end

  test "additional keys obey billing and are removed with their router", ctx do
    {:ok, key, secret} = Routers.create_api_key(ctx.scope, ctx.router.id, %{name: "CI"})
    set_subscription_status(ctx.scope.user, nil)
    conn = Plug.Test.conn(:post, "/") |> put_req_header("authorization", "Bearer " <> secret)
    assert ApiAuth.call(conn, []).status == 402
    assert {:ok, _} = Routers.delete_router(ctx.router)
    assert is_nil(Repo.get(Routers.ApiKey, key.id))
    assert is_nil(Routers.get_router_by_api_key(secret))
  end
end
