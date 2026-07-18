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

  test "code_change migrates the legacy state shape" do
    legacy = %{"router-id" => %{"req-id" => :primary}}

    assert {:ok, %{routers: ^legacy, owners: %{}}} = Activity.code_change(:legacy, legacy, nil)

    migrated = %{routers: legacy, owners: %{}}
    assert {:ok, ^migrated} = Activity.code_change(:legacy, migrated, nil)
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
