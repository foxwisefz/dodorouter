defmodule DodoRouter.EvaluationsApplyVerdictTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Routers
  alias DodoRouter.RoutersFixtures

  defp setup_verdict(_context) do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    incumbent_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Incumbent key"})
    candidate_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Candidate key"})

    {:ok, step} =
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
        name: "Downgrade check",
        criteria: "Answer accurately",
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

    %{
      user: user,
      router: router,
      step: step,
      evaluation: evaluation,
      incumbent_key: incumbent_key,
      candidate_key: candidate_key
    }
  end

  setup :setup_verdict

  test "applying updates the incumbent's step and records the auditable link", %{
    user: user,
    router: router,
    step: step,
    evaluation: evaluation,
    candidate_key: candidate_key
  } do
    assert {:ok, updated, event} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => candidate_key.id,
               "model" => "cheap-model"
             })

    assert updated.id == step.id
    assert updated.model == "cheap-model"
    assert updated.provider_key_id == candidate_key.id
    # Knobs the benchmark did not measure stay untouched.
    assert updated.reasoning_effort == step.reasoning_effort
    assert updated.temperature == step.temperature

    assert event.router_id == router.id
    assert event.evaluation_id == evaluation.id
    assert event.before_step["model"] == "incumbent-model"
    assert event.before_step["provider_key_label"] == "Incumbent key"
    assert event.after_step["model"] == "cheap-model"
    assert event.after_step["provider_key_label"] == "Candidate key"

    assert [%{id: listed_id}] = Evaluations.list_applied_changes(evaluation)
    assert listed_id == event.id
  end

  test "reverting restores the recorded before-state exactly once", %{
    user: user,
    step: step,
    evaluation: evaluation,
    candidate_key: candidate_key,
    incumbent_key: incumbent_key
  } do
    {:ok, _updated, event} =
      Evaluations.apply_verdict(user, evaluation, %{
        "provider_key_id" => candidate_key.id,
        "model" => "cheap-model"
      })

    assert {:ok, reverted} = Evaluations.revert_verdict(user, event.id)
    assert reverted.id == step.id
    assert reverted.model == "incumbent-model"
    assert reverted.provider_key_id == incumbent_key.id

    assert [%{reverted_at: %DateTime{}}] = Evaluations.list_applied_changes(evaluation)
    assert {:error, :already_reverted} = Evaluations.revert_verdict(user, event.id)

    # Someone else's event is indistinguishable from a missing one.
    other = AccountsFixtures.user_fixture()
    assert {:error, :not_found} = Evaluations.revert_verdict(other, event.id)
  end

  test "refuses when no step, or more than one, serves the incumbent", %{
    user: user,
    router: router,
    step: step,
    evaluation: evaluation,
    candidate_key: candidate_key,
    incumbent_key: incumbent_key
  } do
    # A second identical step makes the target ambiguous.
    {:ok, _twin} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "incumbent-model",
        "provider_key_id" => incumbent_key.id
      })

    assert {:error, :ambiguous_step} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => candidate_key.id,
               "model" => "cheap-model"
             })

    # With the routing edited away from the incumbent, there is no safe target.
    for s <- Routers.list_routing_steps(router), do: {:ok, _} = Routers.delete_routing_step(s)

    {:ok, _other} =
      Routers.create_routing_step(router, %{
        "provider" => "test_provider",
        "model" => "some-other-model",
        "provider_key_id" => incumbent_key.id
      })

    assert {:error, :no_matching_step} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => candidate_key.id,
               "model" => "cheap-model"
             })

    _ = step
  end

  test "refuses variants, foreign keys, and no-op applies", %{
    user: user,
    evaluation: evaluation,
    candidate_key: candidate_key,
    incumbent_key: incumbent_key
  } do
    assert {:error, :variant_not_applicable} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => candidate_key.id,
               "model" => "cheap-model",
               "variant" => "terse"
             })

    other = AccountsFixtures.user_fixture()
    foreign_key = ProvidersFixtures.provider_key_fixture(other)

    assert {:error, :unknown_key} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => foreign_key.id,
               "model" => "cheap-model"
             })

    assert {:error, :already_serving} =
             Evaluations.apply_verdict(user, evaluation, %{
               "provider_key_id" => incumbent_key.id,
               "model" => "incumbent-model"
             })
  end
end
