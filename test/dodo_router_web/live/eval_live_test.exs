defmodule DodoRouterWeb.EvalLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouter.LogsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.EvaluationRun
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Repo
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  test "creates an evaluation from a selected log", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")
    assert has_element?(live, "#eval-form")

    live
    |> form("#candidate-picker-form", %{"picker" => %{"provider" => provider_key.id}})
    |> render_change()

    live
    |> form("#candidate-picker-form", %{
      "picker" => %{
        "provider" => provider_key.id,
        "target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    assert has_element?(live, "#selected-candidates input[value='#{provider_key.id}|test-model']") or
             has_element?(live, "#selected-candidates", "test-model")

    live
    |> form("#eval-form", %{
      "evaluation" => %{
        "name" => "Concise and correct",
        "criteria" => "Answer accurately without unnecessary detail",
        "candidate_target_values" => ["#{provider_key.id}|test-model"],
        "repetitions" => "3",
        "judge_target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    {path, _flash} = assert_redirect(live)
    assert String.starts_with?(path, "/evals/")

    assert {:ok, show_live, _html} = live(conn, URI.parse(path).path)
    assert has_element?(show_live, "#eval-summary")
  end

  test "redirects a stale evaluation URL instead of raising", %{conn: conn} do
    missing_id = Ecto.UUID.generate()

    assert {:error, {:live_redirect, %{to: "/evals"}}} = live(conn, ~p"/evals/#{missing_id}")
  end

  test "denies access to another user's evaluation", %{conn: conn} do
    other_user = DodoRouter.AccountsFixtures.user_fixture()
    {other_router, _api_key} = RoutersFixtures.router_fixture(other_user)
    other_key = ProvidersFixtures.provider_key_fixture(other_user)
    other_log = LogsFixtures.log_fixture(other_router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(other_user, other_log, %{
        name: "Not yours",
        criteria: "Be correct",
        judge_model: "test-model",
        judge_provider_key_id: other_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => other_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ]
      })

    assert {:error, {:live_redirect, %{to: "/evals"}}} = live(conn, ~p"/evals/#{evaluation.id}")
  end

  test "run history links to candidate and judge logs", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    source = LogsFixtures.log_fixture(router)
    candidate = LogsFixtures.log_fixture(router)
    judge = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, source, %{
        name: "Linked logs",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ]
      })

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "failed",
      candidate_model: "test-model",
      candidate_provider: "test_provider",
      repetition: 1,
      candidate_log_id: candidate.id,
      judge_log_id: judge.id
    })
    |> Repo.insert!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # Errored runs are collapsed by default; reveal them first.
    live |> element("#toggle-errored-legacy") |> render_click()

    assert has_element?(live, "#eval-runs a[href='/logs/#{candidate.id}']", "Candidate log")
    assert has_element?(live, "#eval-runs a[href='/logs/#{judge.id}']", "Judge log")
    assert has_element?(live, "#eval-runs", "Errored")
  end

  test "groups run history by batch and hides errored runs behind a toggle",
       %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Batched history",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ]
      })

    old_batch = Ecto.UUID.generate()
    new_batch = Ecto.UUID.generate()

    insert_run = fn attrs ->
      %EvaluationRun{}
      |> EvaluationRun.changeset(
        Map.merge(
          %{
            evaluation_id: evaluation.id,
            candidate_provider: "test_provider",
            candidate_model: "test-model",
            repetition: 1
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    _old_run = insert_run.(%{status: "completed", score: 60, passed: false, batch_id: old_batch})
    scored = insert_run.(%{status: "completed", score: 90, passed: true, batch_id: new_batch})
    errored = insert_run.(%{status: "failed", error: "boom", batch_id: new_batch, repetition: 2})

    evaluation
    |> Ecto.Changeset.change(last_batch_id: new_batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # One section per batch, latest first with its own label.
    assert has_element?(live, "#batch-#{new_batch}", "Latest batch")
    assert has_element?(live, "#batch-#{old_batch}")

    # Errored runs stay collapsed until toggled, scored runs show right away.
    assert has_element?(live, "#run-#{scored.id}")
    refute has_element?(live, "#run-#{errored.id}")
    assert has_element?(live, "#toggle-errored-#{new_batch}", "1 errored")

    live |> element("#toggle-errored-#{new_batch}") |> render_click()
    assert has_element?(live, "#run-#{errored.id}")

    live |> element("#toggle-errored-#{new_batch}") |> render_click()
    refute has_element?(live, "#run-#{errored.id}")
  end

  test "chart draws lines, marks errored runs, and pins a series on click",
       %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Chart",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "model-a"
          },
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "model-b"
          }
        ],
        repetitions: 2
      })

    batch = Ecto.UUID.generate()

    insert_run = fn attrs ->
      %EvaluationRun{}
      |> EvaluationRun.changeset(
        Map.merge(
          %{
            evaluation_id: evaluation.id,
            candidate_provider: "test_provider",
            batch_id: batch
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    insert_run.(%{
      candidate_model: "model-a",
      repetition: 1,
      status: "completed",
      score: 90,
      passed: true
    })

    insert_run.(%{
      candidate_model: "model-a",
      repetition: 2,
      status: "completed",
      score: 88,
      passed: true
    })

    insert_run.(%{
      candidate_model: "model-b",
      repetition: 1,
      status: "completed",
      score: 70,
      passed: true
    })

    insert_run.(%{candidate_model: "model-b", repetition: 2, status: "failed", error: "boom"})

    evaluation
    |> Ecto.Changeset.change(last_batch_id: batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # Rankings sort by average: model-a (89) is series 0, model-b (70) is 1.
    assert has_element?(live, "#chart-series-0 polyline")
    assert has_element?(live, "#chart-legend-0", "2 scored")
    assert has_element?(live, "#chart-legend-1", "1 errored")

    # Errored runs never render as chart marks — legend counts only.
    refute has_element?(live, "#quality-consistency-chart .errored-mark")

    # Clicking a legend entry pins its series and dims the others.
    live |> element("#chart-legend-0") |> render_click()
    assert has_element?(live, "#chart-series-0[opacity='1']")
    assert has_element?(live, "#chart-series-1[opacity='0.15']")

    # Clicking again unpins.
    live |> element("#chart-legend-0") |> render_click()
    assert has_element?(live, "#chart-series-1[opacity='1']")

    # Pinning a series with failures highlights its errored count.
    refute has_element?(live, "#chart-legend-errored-1.text-error")
    live |> element("#chart-legend-1") |> render_click()
    assert has_element?(live, "#chart-legend-errored-1.text-error")
  end
end
