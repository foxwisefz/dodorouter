defmodule DodoRouter.EvaluationsMonitorTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.{EvaluationRun, RequestLog}
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  defp setup_monitor(_context) do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    incumbent_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Incumbent key"})
    candidate_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Candidate key"})

    {:ok, _step} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "incumbent-model",
        "provider_key_id" => incumbent_key.id
      })

    log =
      LogsFixtures.log_fixture(router, %{
        final_model: "incumbent-model",
        attempted_steps: [
          %{
            "status" => "success",
            "provider_key_id" => incumbent_key.id,
            "model" => "incumbent-model"
          }
        ]
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Downgrade watch",
        criteria: "Answer accurately",
        # TestProvider answers "judge-model" calls with a parseable
        # judgement scoring 82.
        judge_model: "judge-model",
        judge_provider_key_id: candidate_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => candidate_key.id,
            "provider" => "test_provider",
            "model" => "cheap-model"
          }
        ]
      })

    # An accepted benchmark result for the applied model: the monitor's
    # baseline comes from here.
    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "completed",
      score: 82,
      candidate_provider: "test_provider",
      candidate_model: "cheap-model"
    })
    |> Repo.insert!()

    {:ok, _step, event} =
      Evaluations.apply_verdict(user, evaluation, %{
        "provider_key_id" => candidate_key.id,
        "model" => "cheap-model"
      })

    %{user: user, router: router, evaluation: evaluation, event: event}
  end

  setup :setup_monitor

  defp live_log(router, text) do
    LogsFixtures.log_fixture(router, %{
      final_model: "cheap-model",
      request_body:
        Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => text}]}),
      response_body:
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "served: #{text}"}}]
        })
    })
  end

  # A sweep only samples logs newer than the last one; rewinding beats
  # sleeping across the timestamp granularity.
  defp rewind(monitor) do
    monitor
    |> Ecto.Changeset.change(last_sampled_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()
  end

  test "enabling anchors the baseline to the applied model's own ranking", %{
    user: user,
    evaluation: evaluation,
    event: event
  } do
    assert {:ok, monitor} = Evaluations.enable_monitor(user, evaluation, event)
    assert monitor.baseline_avg == 82
    assert monitor.target_model == "cheap-model"
    assert monitor.status == "active"

    assert {:error, :already_monitoring} = Evaluations.enable_monitor(user, evaluation, event)
  end

  test "a sweep judges recent live answers without generating anything", %{
    user: user,
    router: router,
    evaluation: evaluation,
    event: event
  } do
    {:ok, monitor} = Evaluations.enable_monitor(user, evaluation, event)

    live_log(router, "one")
    live_log(router, "two")
    # Wrong model: live traffic the monitor is not about.
    LogsFixtures.log_fixture(router, %{final_model: "unrelated-model"})

    assert {:ok, swept} = Evaluations.sweep_monitor(monitor)
    assert swept.last_sampled_at
    assert swept.consecutive_drops == 0

    runs = Evaluations.monitor_runs(evaluation)
    assert length(runs) == 2

    assert Enum.all?(
             runs,
             &(&1.kind == "monitor" and &1.status == "completed" and &1.score == 82)
           )

    assert Enum.all?(runs, &(&1.candidate_output =~ "served:"))

    # Monitor runs never leak into the benchmark's aggregates.
    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert [%{total: 1}] = Evaluations.rankings(loaded)
  end

  test "a sustained drop below baseline raises the alert, and recovery clears it", %{
    user: user,
    router: router,
    evaluation: evaluation,
    event: event
  } do
    {:ok, monitor} = Evaluations.enable_monitor(user, evaluation, event)

    # Live scores will come in at 82; a baseline of 95 puts them below
    # baseline - tolerance.
    monitor = monitor |> Ecto.Changeset.change(baseline_avg: 95) |> Repo.update!()

    for text <- ~w(a b c), do: live_log(router, text)
    assert {:ok, monitor} = Evaluations.sweep_monitor(monitor)
    assert monitor.consecutive_drops == 1
    assert monitor.alerted_at == nil

    monitor = rewind(monitor)
    for text <- ~w(d e f), do: live_log(router, text)
    assert {:ok, monitor} = Evaluations.sweep_monitor(monitor)
    assert monitor.consecutive_drops == 2
    assert %DateTime{} = monitor.alerted_at

    # Recovery: with the baseline back within reach, the alert clears
    # rather than lingering as a stale grudge.
    monitor = monitor |> Ecto.Changeset.change(baseline_avg: 82) |> Repo.update!()
    monitor = rewind(monitor)
    for text <- ~w(g h i), do: live_log(router, text)
    assert {:ok, monitor} = Evaluations.sweep_monitor(monitor)
    assert monitor.consecutive_drops == 0
    assert monitor.alerted_at == nil
  end

  test "due_monitors respects interval and status", %{
    user: user,
    evaluation: evaluation,
    event: event
  } do
    {:ok, monitor} = Evaluations.enable_monitor(user, evaluation, event)

    # Never sampled: due immediately.
    assert Enum.any?(Evaluations.due_monitors(), &(&1.id == monitor.id))

    monitor =
      monitor |> Ecto.Changeset.change(last_sampled_at: DateTime.utc_now()) |> Repo.update!()

    refute Enum.any?(Evaluations.due_monitors(), &(&1.id == monitor.id))

    {:ok, _paused} = Evaluations.pause_monitor(user, monitor.id)

    later = DateTime.add(DateTime.utc_now(), 25 * 3600, :second)
    refute Enum.any?(Evaluations.due_monitors(later), &(&1.id == monitor.id))

    {:ok, _resumed} = Evaluations.resume_monitor(user, monitor.id)
    assert Enum.any?(Evaluations.due_monitors(later), &(&1.id == monitor.id))
  end

  test "served_answer reads both wire formats" do
    openai = %RequestLog{
      response_body:
        Jason.encode!(%{"choices" => [%{"message" => %{"content" => "plain answer"}}]})
    }

    anthropic = %RequestLog{
      response_body:
        Jason.encode!(%{
          "content" => [
            %{"type" => "text", "text" => "first"},
            %{"type" => "tool_use", "name" => "search", "input" => %{"q" => "x"}},
            %{"type" => "text", "text" => "second"}
          ]
        })
    }

    assert Evaluations.served_answer(openai) == "plain answer"
    answer = Evaluations.served_answer(anthropic)
    assert answer =~ "first"
    assert answer =~ ~s([tool call] search)
    assert answer =~ "second"

    assert Evaluations.served_answer(%RequestLog{response_body: nil}) == nil
  end
end
