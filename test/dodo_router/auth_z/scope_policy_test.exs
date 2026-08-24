defmodule DodoRouter.AuthZ.ScopePolicyTest do
  use ExUnit.Case, async: true

  alias DodoRouter.AuthZ.ScopePolicy

  @uuid "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

  test "grants known permission scopes" do
    assert {:ok, ["logs:read", "evals:read"]} =
             ScopePolicy.authorize_scope(nil, ["logs:read", "evals:read"])
  end

  test "rejects unknown scopes loudly rather than narrowing" do
    assert {:error, :invalid_scope} = ScopePolicy.authorize_scope(nil, ["logs:read", "typo"])
  end

  test "grants router narrowing scopes alongside permissions" do
    assert {:ok, ["logs:read", "router:" <> @uuid]} =
             ScopePolicy.authorize_scope(nil, ["logs:read", "router:" <> @uuid])
  end

  test "rejects a router scope whose id is not a UUID" do
    assert {:error, :invalid_scope} =
             ScopePolicy.authorize_scope(nil, ["logs:read", "router:my-router"])
  end

  test "rejects router scopes with no permission scopes" do
    # Reach with no permissions is a token that can do nothing anywhere.
    assert {:error, :invalid_scope} = ScopePolicy.authorize_scope(nil, ["router:" <> @uuid])
  end
end
