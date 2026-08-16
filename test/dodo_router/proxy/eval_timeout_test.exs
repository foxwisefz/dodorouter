defmodule DodoRouter.Proxy.EvalTimeoutTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Proxy
  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.RoutersFixtures

  test "the deadline policy is pure and explicit" do
    assert Adapter.receive_timeout_for("evaluation_candidate") == 600_000
    assert Adapter.receive_timeout_for("evaluation_judge") == 600_000
    assert Adapter.receive_timeout_for("proxy") == 120_000
    assert Adapter.receive_timeout_for(nil) == 120_000
  end

  # The seam: FallbackChain sets the deadline per dispatch from the traffic
  # type, and the adapter's Req call reads it in the same process.
  # TestProvider echoes what it saw into _meta.
  test "eval replays wait for the answer; live traffic fails over" do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)

    {:ok, _step} =
      DodoRouter.Routers.create_routing_step(router, %{
        position: 0,
        provider: "test_provider",
        model: "test-model",
        provider_key_id: key.id
      })

    request = %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}

    {:ok, response, _meta} =
      Proxy.dispatch(router, request, traffic_type: "evaluation_candidate", log_mode: :sync)

    assert response["_meta"]["receive_timeout_ms"] == 600_000

    {:ok, response, _meta} = Proxy.dispatch(router, request, log_mode: :sync)
    assert response["_meta"]["receive_timeout_ms"] == 120_000

    # A stale key from a previous eval dispatch in the same process must
    # never leak onto live traffic — the chain sets it unconditionally.
    Adapter.put_receive_timeout("evaluation_candidate")

    {:ok, response, _meta} =
      Proxy.dispatch(router, request, traffic_type: "proxy", log_mode: :sync)

    assert response["_meta"]["receive_timeout_ms"] == 120_000
  end
end
