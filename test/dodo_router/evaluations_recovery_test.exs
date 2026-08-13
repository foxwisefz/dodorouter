defmodule DodoRouter.EvaluationsRecoveryTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.{Evaluation, EvaluationRun}
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  # A benchmark lives in a task, not in the database. Restart the VM — a
  # deploy, a crash, `mix phx.server` in a terminal that got Ctrl-C'd — and
  # every run it had in flight is orphaned: rows saying "running" that no
  # process will ever finish, and an evaluation saying "running" that can
  # never say anything else.
  #
  # Boot is the one moment we can be certain nothing is executing, so it is
  # the moment to say so.
  defp stranded_evaluation do
    user = AccountsFixtures.user_fixture()
    {router, _} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Interrupted by a restart",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    batch = Ecto.UUID.generate()

    evaluation =
      evaluation
      |> Ecto.Changeset.change(last_batch_id: batch, benchmark_status: "running")
      |> Repo.update!()

    runs =
      for {status, repetition} <- [{"pending", 1}, {"running", 2}, {"completed", 3}] do
        %EvaluationRun{}
        |> EvaluationRun.changeset(%{
          evaluation_id: evaluation.id,
          batch_id: batch,
          status: status,
          score: if(status == "completed", do: 70),
          candidate_provider: "test_provider",
          candidate_model: "test-model",
          repetition: repetition
        })
        |> Repo.insert!()
      end

    {user, evaluation, runs}
  end

  test "recovery resolves runs no process will ever finish" do
    {_user, evaluation, [pending, running, completed]} = stranded_evaluation()

    assert {2, _} = Evaluations.recover_interrupted()

    for id <- [pending.id, running.id] do
      run = Repo.get!(EvaluationRun, id)
      assert run.status == "failed"
      assert run.error =~ "stopped before this run finished"
    end

    # A finished run is not touched: it is a result, not a leftover.
    assert Repo.get!(EvaluationRun, completed.id).status == "completed"
    _ = evaluation
  end

  test "recovery stops an evaluation claiming to run forever" do
    {_user, evaluation, _runs} = stranded_evaluation()

    Evaluations.recover_interrupted()

    # One scored run out of three: the batch was partly done, and that is
    # what the status should say — not "running", and not "failed".
    assert Repo.get!(Evaluation, evaluation.id).benchmark_status == "partial"
  end

  test "recovery is idempotent" do
    {_user, _evaluation, _runs} = stranded_evaluation()

    assert {2, _} = Evaluations.recover_interrupted()
    assert {0, _} = Evaluations.recover_interrupted()
  end

  test "an evaluation that was never running is left alone" do
    user = AccountsFixtures.user_fixture()
    {router, _} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, draft} =
      Evaluations.create_evaluation(user, log, %{
        name: "Never run",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: []
      })

    Evaluations.recover_interrupted()

    assert Repo.get!(Evaluation, draft.id).benchmark_status == "draft"
  end
end
