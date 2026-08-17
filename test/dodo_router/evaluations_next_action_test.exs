defmodule DodoRouter.EvaluationsNextActionTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  defp decision_log(router) do
    LogsFixtures.log_fixture(router, %{
      final_model: "incumbent-model",
      request_body:
        Jason.encode!(%{
          "model" => "m",
          "messages" => [%{"role" => "user", "content" => "fix the failing test"}]
        }),
      response_body:
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"role" => "assistant", "content" => "I will read the test first"}}
          ]
        })
    })
  end

  test "the next_action judge sees both actions and must state a preference" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = decision_log(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Per-decision",
        criteria: "Advance the task",
        judge_model: "judge-model",
        judge_provider_key_id: key.id,
        comparison_mode: "next_action",
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    request = Evaluations.judge_request(evaluation, log, "grep for the test name")
    [_system, %{"content" => prompt}] = request["messages"]

    assert prompt =~ "RECORDED_ACTION"
    assert prompt =~ "I will read the test first"
    assert prompt =~ "grep for the test name"
    assert prompt =~ ~s("preference")

    # The same evaluation in rubric mode never mentions a recorded action.
    rubric = %{evaluation | comparison_mode: nil}
    rubric_request = Evaluations.judge_request(rubric, log, "grep for the test name")
    [_system, %{"content" => rubric_prompt}] = rubric_request["messages"]
    refute rubric_prompt =~ "RECORDED_ACTION"
  end

  test "preference parses case-insensitively and junk reads as unstated" do
    {:ok, parsed} =
      Evaluations.parse_judgement(
        Jason.encode!(%{"score" => 70, "summary" => "ok", "preference" => "Better"})
      )

    assert parsed.preference == "better"

    {:ok, parsed} =
      Evaluations.parse_judgement(
        Jason.encode!(%{"score" => 70, "summary" => "ok", "preference" => "much better"})
      )

    assert parsed.preference == nil

    {:ok, parsed} =
      Evaluations.parse_judgement(Jason.encode!(%{"score" => 70, "summary" => "ok"}))

    assert parsed.preference == nil
  end

  test "a next_action benchmark records preferences and rolls up decisions" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = decision_log(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Per-decision",
        criteria: "Advance the task",
        judge_model: "judge-model",
        judge_provider_key_id: key.id,
        comparison_mode: "next_action",
        repetitions: 2,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    {:ok, _results} = Evaluations.run(user, evaluation)

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    runs = Evaluations.latest_batch_runs(loaded)

    assert length(runs) == 2
    assert Enum.all?(runs, &(&1.status == "completed" and &1.preference == "better"))
    # The version names the prompt the judge actually saw — these scores are
    # not comparable with rubric scores.
    assert Enum.all?(runs, &(&1.judge_prompt_version =~ "next-action"))

    assert [%{decisions: decisions}] = Evaluations.rankings(loaded)
    assert decisions == %{better: 2, equivalent: 0, worse: 0, preferred_pct: 100}
  end

  test "rubric-mode benchmarks carry no preference even when the judge offers one" do
    # TestProvider's canned judgement includes preference: "better"; a
    # rubric run must not record a field the judge was never asked for.
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = decision_log(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Rubric",
        criteria: "Advance the task",
        judge_model: "judge-model",
        judge_provider_key_id: key.id,
        repetitions: 1,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    {:ok, _results} = Evaluations.run(user, evaluation)

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert [run] = Evaluations.latest_batch_runs(loaded)
    assert run.preference == nil
    assert [%{decisions: nil}] = Evaluations.rankings(loaded)
  end

  test "next_action_blocker names a log with no extractable recorded action" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)

    with_answer = decision_log(router)
    without_answer = LogsFixtures.log_fixture(router)

    assert Evaluations.next_action_blocker(with_answer) == nil
    assert Evaluations.next_action_blocker(without_answer) == :no_recorded_action
  end

  test "comparison_mode reads rubric for every pre-mode row" do
    assert Evaluation.comparison_mode(%Evaluation{comparison_mode: nil}) == "rubric"

    assert Evaluation.comparison_mode(%Evaluation{comparison_mode: "next_action"}) ==
             "next_action"
  end
end
