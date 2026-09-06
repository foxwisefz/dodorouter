defmodule DodoRouter.Logs.CacheDiagnosticsStorageTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Logs.CacheDiagnostics
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  defp attrs(router, content, start, extra \\ %{}) do
    fp =
      CacheDiagnostics.fingerprint(
        %{"messages" => [%{"role" => "user", "content" => content}]},
        router.id,
        started_at_ms: start,
        finished_at_ms: start + 10,
        routing: "same"
      )

    LogsFixtures.valid_log_attributes(
      router,
      Map.merge(
        %{
          cache_fingerprint: fp,
          cache_read_tokens: 0,
          cache_write_tokens: 100,
          session_id: "session",
          traffic_type: "proxy",
          request_body: nil
        },
        extra
      )
    )
  end

  test "persists a diagnosis without bodies and scopes comparison to router/session" do
    {router, _} = RoutersFixtures.router_fixture()
    {other, _} = RoutersFixtures.router_fixture()
    {:ok, first} = Logs.create_log(attrs(router, "before", 1000))
    {:ok, _} = Logs.create_log(attrs(other, "unrelated", 1500))
    {:ok, _} = Logs.create_log(attrs(router, "unrelated", 1500, %{session_id: "other"}))
    {:ok, current} = Logs.create_log(attrs(router, "after", 2000))
    assert current.request_body == nil
    assert current.cache_diagnosis["cause"] == "prefix_changed"
    assert current.cache_diagnosis["previous_log_id"] == first.id
  end

  test "sessionless traffic and replay rows are not baselines" do
    {router, _} = RoutersFixtures.router_fixture()
    {:ok, first} = Logs.create_log(attrs(router, "before", 1000))

    {:ok, _} =
      Logs.create_log(attrs(router, "replayed", 1500, %{idempotent_replay_of_id: first.id}))

    {:ok, current} = Logs.create_log(attrs(router, "after", 2000))
    assert current.cache_diagnosis["previous_log_id"] == first.id
    {:ok, no_session} = Logs.create_log(attrs(router, "after", 3000, %{session_id: nil}))
    assert no_session.cache_diagnosis["previous_log_id"] == nil
  end

  test "a request that started later cannot be used as a predecessor" do
    {router, _} = RoutersFixtures.router_fixture()
    {:ok, _} = Logs.create_log(attrs(router, "later", 5000))
    {:ok, current} = Logs.create_log(attrs(router, "earlier", 2000))
    assert current.cache_diagnosis["previous_log_id"] == nil
  end

  test "out-of-order completion compares the latest preceding start, not the latest insert" do
    {router, _} = RoutersFixtures.router_fixture()
    {:ok, latest_start} = Logs.create_log(attrs(router, "second", 2000))
    {:ok, _} = Logs.create_log(attrs(router, "first", 1000))
    {:ok, current} = Logs.create_log(attrs(router, "third", 3000))
    assert current.cache_diagnosis["previous_log_id"] == latest_start.id
  end
end
