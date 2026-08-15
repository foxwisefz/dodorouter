defmodule DodoRouter.Models.SyncSchedulerTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Models.SyncScheduler

  # The point of this module is that it runs without being asked: the sync it
  # wraps had no callers anywhere in the repo, so the catalog was only ever as
  # current as somebody's memory — 40 days, when this was written.
  test "is supervised, so it starts with the app rather than on request" do
    pid = Process.whereis(SyncScheduler)

    assert is_pid(pid), "SyncScheduler is not in the supervision tree"
    assert Process.alive?(pid)
  end

  test "schedules nothing while the SQL sandbox is on" do
    # A timer firing mid-suite would write outside any test's ownership.
    assert Application.get_env(:dodo_router, :sql_sandbox, false)
    refute SyncScheduler.enabled?()
  end

  test "can be switched off for a deployment that wants a pinned catalog" do
    Application.put_env(:dodo_router, :models_sync_enabled, false)
    refute SyncScheduler.enabled?()
  after
    Application.put_env(:dodo_router, :models_sync_enabled, false)
  end

  test "keeps its state across a hot upgrade" do
    assert {:ok, %{last_result: nil}} =
             SyncScheduler.code_change("0.1.0", %{last_result: nil}, [])
  end
end
