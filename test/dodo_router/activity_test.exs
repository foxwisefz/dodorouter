defmodule DodoRouter.ActivityTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Activity

  # Activity is a globally named GenServer shared across async tests,
  # so every test uses freshly generated router ids to stay isolated.

  test "tracks request lifecycle from the calling process" do
    router_id = Ecto.UUID.generate()

    Activity.request_started(router_id, "req-1")
    wait_until(fn -> Activity.get_router_counts(router_id) == {1, 0} end)

    Activity.step_started(router_id, "req-1", 1)
    wait_until(fn -> Activity.get_router_counts(router_id) == {0, 1} end)

    Activity.request_completed(router_id, "req-1")
    wait_until(fn -> Activity.get_router_counts(router_id) == {0, 0} end)
  end

  test "drops entries when the owning process is killed" do
    router_id = Ecto.UUID.generate()
    test_pid = self()

    pid =
      spawn(fn ->
        Activity.request_started(router_id, "doomed-req")
        send(test_pid, :registered)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :registered
    wait_until(fn -> Activity.get_router_counts(router_id) == {1, 0} end)

    Process.exit(pid, :kill)

    wait_until(fn -> Activity.get_router_counts(router_id) == {0, 0} end)
  end

  test "drops all of a dead owner's entries across routers" do
    router_a = Ecto.UUID.generate()
    router_b = Ecto.UUID.generate()
    test_pid = self()

    pid =
      spawn(fn ->
        Activity.request_started(router_a, "req-a1")
        Activity.request_started(router_a, "req-a2")
        Activity.request_started(router_b, "req-b1")
        send(test_pid, :registered)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :registered
    wait_until(fn -> Activity.get_total_active([router_a, router_b]) == 3 end)

    Process.exit(pid, :kill)

    wait_until(fn -> Activity.get_total_active([router_a, router_b]) == 0 end)
  end

  test "completed requests do not reappear when the owner later dies" do
    router_id = Ecto.UUID.generate()
    test_pid = self()

    pid =
      spawn(fn ->
        Activity.request_started(router_id, "req-1")
        Activity.request_completed(router_id, "req-1")
        Activity.request_started(router_id, "req-2")
        send(test_pid, :registered)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :registered
    wait_until(fn -> Activity.get_router_counts(router_id) == {1, 0} end)

    Process.exit(pid, :kill)

    wait_until(fn -> Activity.get_router_counts(router_id) == {0, 0} end)
  end

  test "stores pending logs and lists them newest-first until completion" do
    router_id = Ecto.UUID.generate()

    older = pending_log(router_id, "req-1", DateTime.add(DateTime.utc_now(), -60, :second))
    newer = pending_log(router_id, "req-2", DateTime.utc_now())

    Activity.request_started(router_id, "req-1", older)
    Activity.request_started(router_id, "req-2", newer)

    wait_until(fn ->
      match?([%{request_id: "req-2"}, %{request_id: "req-1"}], Activity.list_pending([router_id]))
    end)

    Activity.request_completed(router_id, "req-2")
    wait_until(fn -> match?([%{request_id: "req-1"}], Activity.list_pending([router_id])) end)

    Activity.request_completed(router_id, "req-1")
    wait_until(fn -> Activity.list_pending([router_id]) == [] end)
  end

  test "step_started moves the stored pending log to the backup step" do
    router_id = Ecto.UUID.generate()

    Activity.request_started(router_id, "req-1", pending_log(router_id, "req-1"))
    wait_until(fn -> length(Activity.list_pending([router_id])) == 1 end)

    Activity.step_started(router_id, "req-1", 1, %{
      provider: "moonshot",
      model: "kimi-k2.6",
      plan_type: "coding"
    })

    wait_until(fn ->
      case Activity.list_pending([router_id]) do
        [
          %{
            final_provider: "moonshot",
            final_model: "kimi-k2.6",
            attempted_steps: [first, second]
          }
        ] ->
          first["status"] == "error" and second["provider"] == "moonshot"

        _ ->
          false
      end
    end)
  end

  test "owner death clears stored pending logs" do
    router_id = Ecto.UUID.generate()
    test_pid = self()

    pid =
      spawn(fn ->
        Activity.request_started(router_id, "doomed-req", pending_log(router_id, "doomed-req"))
        send(test_pid, :registered)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :registered
    wait_until(fn -> length(Activity.list_pending([router_id])) == 1 end)

    Process.exit(pid, :kill)

    wait_until(fn -> Activity.list_pending([router_id]) == [] end)
  end

  test "code_change migrates the legacy state shapes" do
    legacy = %{"router-id" => %{"req-id" => :primary}}
    migrated = %{"router-id" => %{"req-id" => %{status: :primary, log: nil}}}

    # Pre-owners shape: bare routers map with atom statuses
    assert {:ok, %{routers: ^migrated, owners: %{}}} = Activity.code_change(:legacy, legacy, nil)

    # Owners present but entries still atoms
    assert {:ok, %{routers: ^migrated, owners: %{}}} =
             Activity.code_change(:legacy, %{routers: legacy, owners: %{}}, nil)

    # Current shape passes through unchanged
    current = %{routers: migrated, owners: %{}}
    assert {:ok, ^current} = Activity.code_change(:legacy, current, nil)
  end

  defp pending_log(router_id, request_id, inserted_at \\ DateTime.utc_now()) do
    %{
      id: nil,
      request_id: request_id,
      router_id: router_id,
      status: "pending",
      final_provider: "anthropic",
      final_model: "claude-opus-4-8",
      inserted_at: inserted_at,
      attempted_steps: [%{"provider" => "anthropic", "model" => "claude-opus-4-8"}]
    }
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
