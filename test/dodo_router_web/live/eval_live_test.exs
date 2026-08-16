defmodule DodoRouterWeb.EvalLiveTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias DodoRouter.LogsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.EvaluationRun
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Repo
  alias DodoRouter.RoutersFixtures

  setup :register_and_log_in_user

  test "preselects the incumbent model as a candidate", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        final_model: "test-model",
        attempted_steps: [
          %{"status" => "success", "provider_key_id" => provider_key.id, "model" => "test-model"}
        ]
      })

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")

    # The guide's first rule is "include the model you use today" — the form
    # starts from it rather than asking every user to remember.
    assert has_element?(
             live,
             "#selected-candidates input[value='#{provider_key.id}|test-model']"
           ) or has_element?(live, "#selected-candidates", "test-model")
  end

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

    # The judge key gates its own model list, so it is chosen first.
    live
    |> form("#eval-form", %{"evaluation" => %{"judge_key" => provider_key.id}})
    |> render_change()

    live
    |> form("#eval-form", %{
      "evaluation" => %{
        "name" => "Concise and correct",
        "criteria" => "Answer accurately without unnecessary detail",
        "candidate_target_values" => ["#{provider_key.id}|test-model"],
        "repetitions" => "3",
        "judge_key" => provider_key.id,
        "judge_target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    {path, _flash} = assert_redirect(live)
    assert String.starts_with?(path, "/evals/")
    # The save action enqueues the benchmark itself — no run flag in the
    # URL, so refreshing the destination can never start another run.
    refute path =~ "run="

    evaluation_id = path |> String.trim_leading("/evals/") |> URI.parse() |> Map.fetch!(:path)
    evaluation = Evaluations.get_evaluation!(user, evaluation_id)

    # The enqueued benchmark runs against the batch the save created, and
    # it is done by the time the save action returns — a benchmark still
    # writing after the test ends would be racing the sandbox owner it
    # borrowed its connection from.
    assert evaluation.last_batch_id
    refute evaluation.benchmark_status in ["draft", "running"]
    assert length(evaluation.runs) == 3
    assert Enum.all?(evaluation.runs, &(&1.batch_id == evaluation.last_batch_id))

    assert {:ok, show_live, _html} = live(conn, URI.parse(path).path)
    assert has_element?(show_live, "#eval-summary")
  end

  test "the judge is picked as a key and then that key's models", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    prod_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "prod key"})
    backup_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "backup key"})
    log = LogsFixtures.log_fixture(router)

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")

    # Both keys are offered by label, so which one the judge bills is a
    # visible choice and not a guess between identical model rows.
    for key <- [prod_key, backup_key] do
      assert has_element?(
               live,
               "select[name='evaluation[judge_key]'] option[value='#{key.id}']",
               key.label
             )
    end

    # The model select stays empty — and inert — until a key names it.
    assert has_element?(live, "select[name='evaluation[judge_target]'][disabled]")

    live
    |> form("#eval-form", %{"evaluation" => %{"judge_key" => backup_key.id}})
    |> render_change()

    assert has_element?(
             live,
             "select[name='evaluation[judge_target]'] option[value='#{backup_key.id}|test-model']"
           )

    refute has_element?(
             live,
             "select[name='evaluation[judge_target]'] option[value='#{prod_key.id}|test-model']"
           )

    # Switching keys drops the model chosen under the old one rather than
    # billing it to the new key.
    live
    |> form("#eval-form", %{
      "evaluation" => %{
        "judge_key" => prod_key.id,
        "judge_target" => "#{backup_key.id}|test-model"
      }
    })
    |> render_change()

    refute has_element?(live, "select[name='evaluation[judge_target]'] option[selected]")
  end

  test "a judge used before can be picked again in one click", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "prod key"})
    log = LogsFixtures.log_fixture(router)

    {:ok, _evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Earlier eval",
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

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")

    chip = "#recent-judges button[phx-value-target='#{provider_key.id}|test-model']"

    # The chip names all three parts of the past pick, since a bare model
    # name doesn't say whose key paid for it.
    assert has_element?(live, chip, "prod key")
    assert has_element?(live, chip, "test-model")

    live |> element(chip) |> render_click()

    assert has_element?(
             live,
             "select[name='evaluation[judge_target]'] option[selected][value='#{provider_key.id}|test-model']"
           )

    assert has_element?(
             live,
             "select[name='evaluation[judge_key]'] option[selected][value='#{provider_key.id}']"
           )
  end

  test "warns when the judge would bill against a plan rather than the API", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    metered = ProvidersFixtures.provider_key_fixture(user, %{"label" => "metered"})

    plan =
      ProvidersFixtures.provider_key_fixture(user, %{
        "provider_slug" => "test_provider_coding",
        "label" => "plan key"
      })

    log = LogsFixtures.log_fixture(router)
    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")

    refute has_element?(live, "#judge-billing-warning")

    live
    |> form("#eval-form", %{"evaluation" => %{"judge_key" => plan.id}})
    |> render_change()

    # A judge that gets refused costs every score in the batch, not one run.
    assert has_element?(live, "#judge-billing-warning")
    assert render(live) =~ "Prefer a metered API key"

    live
    |> form("#eval-form", %{"evaluation" => %{"judge_key" => metered.id}})
    |> render_change()

    refute has_element?(live, "#judge-billing-warning")
  end

  test "a recent judge whose key is gone is not offered", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "prod key"})
    log = LogsFixtures.log_fixture(router)

    {:ok, _evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Earlier eval",
        criteria: "Be useful",
        judge_model: "retired-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: []
      })

    {:ok, live, _html} = live(conn, ~p"/logs/#{log.id}/evals/new")

    # The model is no longer in the catalog, so replaying the pick would
    # only fail later, at benchmark time.
    refute has_element?(live, "#recent-judges")
  end

  test "mounting the evaluation page never starts a benchmark", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "No side effects",
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

    # Legacy bookmarked URL with the old run flag: must be inert.
    {:ok, _live, _html} = live(conn, ~p"/evals/#{evaluation.id}?run=true")

    reloaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert reloaded.benchmark_status == "draft"
    assert reloaded.runs == []
  end

  test "duplicates an evaluation into a prefilled builder", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Original",
        criteria: "Should mention gentle shows.",
        good_examples: "Mentions gentle shows early",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 5
      })

    # The show page offers duplication.
    {:ok, show, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    assert has_element?(
             show,
             "#duplicate-eval-button[href='/logs/#{log.id}/evals/new?from=#{evaluation.id}']"
           )

    {:ok, new_live, html} = live(conn, ~p"/logs/#{log.id}/evals/new?from=#{evaluation.id}")

    # Everything carries over, ready to modify.
    assert html =~ "Copy of Original"
    assert html =~ "Should mention gentle shows."
    assert html =~ "Mentions gentle shows early"
    assert has_element?(new_live, "#eval-form input[name='evaluation[repetitions]'][value='5']")

    assert has_element?(
             new_live,
             "select[name='evaluation[judge_target]'] option[selected][value='#{provider_key.id}|test-model']"
           )

    assert has_element?(
             new_live,
             "#selected-candidates input[value='#{provider_key.id}|test-model']"
           ) or has_element?(new_live, "#selected-candidates", "test-model")

    # Submitting creates a NEW evaluation; the original is untouched.
    new_live
    |> form("#eval-form", %{
      "evaluation" => %{
        "name" => "Copy of Original",
        "criteria" => "Should mention gentle shows, twice.",
        "candidate_target_values" => ["#{provider_key.id}|test-model"],
        "repetitions" => "5",
        "judge_target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    {path, _flash} = assert_redirect(new_live)
    assert String.starts_with?(path, "/evals/")
    refute path =~ evaluation.id

    original = Evaluations.get_evaluation!(user, evaluation.id)
    assert original.criteria == "Should mention gentle shows."
  end

  test "ignores duplication from another user's evaluation", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    log = LogsFixtures.log_fixture(router)

    other_user = DodoRouter.AccountsFixtures.user_fixture()
    {other_router, _} = RoutersFixtures.router_fixture(other_user)
    other_key = ProvidersFixtures.provider_key_fixture(other_user)
    other_log = LogsFixtures.log_fixture(other_router)

    {:ok, foreign_eval} =
      Evaluations.create_evaluation(other_user, other_log, %{
        name: "Secret rubric",
        criteria: "Confidential criteria",
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

    {:ok, _live, html} = live(conn, ~p"/logs/#{log.id}/evals/new?from=#{foreign_eval.id}")

    refute html =~ "Secret rubric"
    refute html =~ "Confidential criteria"
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

    # Errored runs collapse behind a toggle only when there is something
    # else to show. This batch is all errors, so they are the result and
    # stand on their own.
    refute has_element?(live, "#toggle-errored-legacy")

    assert has_element?(live, "#eval-runs a[href='/logs/#{candidate.id}']", "Candidate log")
    assert has_element?(live, "#eval-runs a[href='/logs/#{judge.id}']", "Judge log")
    assert has_element?(live, "#eval-runs", "Errored")
  end

  test "one results view: a batch selector switches every section at once",
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

    old_run = insert_run.(%{status: "completed", score: 60, batch_id: old_batch})
    scored = insert_run.(%{status: "completed", score: 90, batch_id: new_batch})
    errored = insert_run.(%{status: "failed", error: "boom", batch_id: new_batch, repetition: 2})

    evaluation
    |> Ecto.Changeset.change(last_batch_id: new_batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # Both batches are listed in the selector; the latest is the default
    # view and the only one whose runs are on the page.
    assert has_element?(live, "#batch-#{new_batch}", "Latest")
    assert has_element?(live, "#batch-#{old_batch}")

    assert has_element?(live, "#run-#{scored.id}")
    assert has_element?(live, "#run-#{errored.id}")
    refute has_element?(live, "#run-#{old_run.id}")

    # The aggregates follow the selection: the latest batch scored 90, the
    # old one 60. Switching rewrites stats, rankings and the run list
    # together — that is the entire point of the selector.
    assert has_element?(live, "#eval-summary", "90/100")
    refute has_element?(live, "#eval-summary", "60/100")

    live |> element("#batch-#{old_batch}") |> render_click()

    assert has_element?(live, "#run-#{old_run.id}")
    refute has_element?(live, "#run-#{scored.id}")
    assert has_element?(live, "#eval-summary", "60/100")
    refute has_element?(live, "#eval-summary", "90/100")

    live |> element("#batch-#{new_batch}") |> render_click()

    assert has_element?(live, "#run-#{scored.id}")
    refute has_element?(live, "#run-#{old_run.id}")

    # Every run shows by default — an errored run is a result, not an
    # advanced option. The toggle exists to *hide* them.
    assert has_element?(live, "#run-#{errored.id}")
    assert has_element?(live, "#toggle-errored-#{new_batch}", "1 errored")

    live |> element("#toggle-errored-#{new_batch}") |> render_click()
    refute has_element?(live, "#run-#{errored.id}")

    live |> element("#toggle-errored-#{new_batch}") |> render_click()
    assert has_element?(live, "#run-#{errored.id}")
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
      score: 90
    })

    insert_run.(%{
      candidate_model: "model-a",
      repetition: 2,
      status: "completed",
      score: 88
    })

    insert_run.(%{
      candidate_model: "model-b",
      repetition: 1,
      status: "completed",
      score: 70
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

  test "shows would-cost at API rates when plan-based runs make batches free",
       %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Would cost",
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

    batch = Ecto.UUID.generate()

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      candidate_provider: "test_provider",
      candidate_model: "test-model",
      repetition: 1,
      batch_id: batch,
      status: "completed",
      score: 90,
      candidate_cost_usd: Decimal.new("0"),
      candidate_list_cost_usd: Decimal.new("0.02"),
      judge_cost_usd: Decimal.new("0.01"),
      judge_list_cost_usd: Decimal.new("0.01")
    })
    |> Repo.insert!()

    evaluation
    |> Ecto.Changeset.change(last_batch_id: batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # Actual spend $0.01, would-cost $0.03 — the hint shows both.
    assert has_element?(live, "#eval-summary", "at API rates")
    # Rankings price the candidate at list rates.
    assert has_element?(live, "#model-rankings", "$0.0200")
  end

  test "omits the API-rates hint when actual and list costs match", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Metered",
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

    batch = Ecto.UUID.generate()

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      candidate_provider: "test_provider",
      candidate_model: "test-model",
      repetition: 1,
      batch_id: batch,
      status: "completed",
      score: 90,
      candidate_cost_usd: Decimal.new("0.02"),
      candidate_list_cost_usd: Decimal.new("0.02")
    })
    |> Repo.insert!()

    evaluation
    |> Ecto.Changeset.change(last_batch_id: batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    refute has_element?(live, "#eval-summary", "at API rates")
  end

  test "surfaces judge reasoning and rubric gaps", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Judge feedback",
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

    batch = Ecto.UUID.generate()

    run =
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        repetition: 1,
        batch_id: batch,
        status: "completed",
        score: 88,
        reasoning: "The reply addresses the request head-on and stays factual.",
        rubric_gaps: ["Criteria never say whether brevity matters"]
      })
      |> Repo.insert!()

    evaluation
    |> Ecto.Changeset.change(last_batch_id: batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # The judge's reasoning is available (collapsed) on the run card.
    assert has_element?(live, "#run-#{run.id} details", "Judge reasoning")
    assert has_element?(live, "#run-#{run.id}", "stays factual")

    # Rubric feedback rolls up onto the criteria card.
    assert has_element?(live, "#rubric-feedback", "1 of 1 scored runs")
    assert has_element?(live, "#rubric-feedback", "brevity matters")
  end

  test "plots quality vs speed with the efficient frontier ringed", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Tradeoff",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "model-a"
          }
        ]
      })

    batch = Ecto.UUID.generate()

    insert_run = fn model, score, latency, cost ->
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        candidate_provider: "test_provider",
        candidate_model: model,
        repetition: 1,
        batch_id: batch,
        status: "completed",
        score: score,
        candidate_latency_ms: latency,
        candidate_cost_usd: cost
      })
      |> Repo.insert!()
    end

    # model-a: best score, slower, priciest. model-b: worse but fastest.
    # model-c: slower AND worse than both (speed-dominated) — but the
    # cheapest, so it joins the frontier when the axis switches to cost.
    insert_run.("model-a", 90, 2000, Decimal.new("0.05"))
    insert_run.("model-b", 70, 1000, Decimal.new("0.02"))
    insert_run.("model-c", 60, 3000, Decimal.new("0.005"))

    evaluation
    |> Ecto.Changeset.change(last_batch_id: batch)
    |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    assert has_element?(live, "#quality-speed-chart")

    # Rankings order (by avg score): model-a = 0, model-b = 1, model-c = 2.
    assert has_element?(live, "#speed-point-0.pareto")
    assert has_element?(live, "#speed-point-1.pareto")
    assert has_element?(live, "#speed-point-2")
    refute has_element?(live, "#speed-point-2.pareto")

    # Switching the axis to cost recomputes the frontier: the cheap slow
    # model becomes efficient.
    live |> element("#tradeoff-axis-cost") |> render_click()
    assert has_element?(live, "#speed-point-2.pareto")

    live |> element("#tradeoff-axis-speed") |> render_click()
    refute has_element?(live, "#speed-point-2.pareto")
  end

  test "chart spreads legacy runs with duplicate repetition numbers", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Legacy pool",
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

    # Two pre-batching executions: batch_id nil, colliding repetition numbers.
    for score <- [90, 80] do
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        repetition: 1,
        status: "completed",
        score: score
      })
      |> Repo.insert!()
    end

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # LazyHTML drops inline-SVG children, so pull the circle positions out
    # of the rendered markup directly. The chart is the only circle source.
    cx_values =
      Regex.scan(~r/<circle\s+cx="([\d.]+)"/, render(live), capture: :all_but_first)

    assert length(cx_values) == 2
    assert length(Enum.uniq(cx_values)) == 2
  end

  describe "a run names its own judge key" do
    setup %{user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      judge = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})
      log = LogsFixtures.log_fixture(router)

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Judged history",
          criteria: "Be useful",
          judge_model: "test-model",
          judge_provider_key_id: judge.id,
          candidate_targets: [
            %{
              "provider_key_id" => judge.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ]
        })

      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        status: "completed",
        score: 90,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        repetition: 1,
        judge_provider_key_id: judge.id,
        judge_provider_key_label: judge.label
      })
      |> Repo.insert!()

      %{evaluation: evaluation, judge: judge}
    end

    test "shows the key it was judged by", %{conn: conn, evaluation: evaluation} do
      {:ok, _live, html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert html =~ "judged by Key 1"
      refute html =~ "deleted"
    end

    test "marks the key as deleted once it is gone", %{
      conn: conn,
      user: user,
      evaluation: evaluation,
      judge: judge
    } do
      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})

      {:ok, _} = DodoRouter.Providers.delete_provider_key(judge, reassign_to: replacement)

      {:ok, _live, html} = live(conn, ~p"/evals/#{evaluation.id}")

      # the run still names what judged it, and says the credential is gone
      assert html =~ "judged by Key 1"
      assert html =~ "deleted"
    end
  end

  describe "a batch that failed" do
    setup %{user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Failed batch",
          criteria: "Be useful",
          judge_model: "fail-model",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ],
          repetitions: 1
        })

      # The production path, so benchmark_status is written the way a real
      # run writes it.
      :ok = Evaluations.enqueue(user, evaluation)

      %{evaluation: Evaluations.get_evaluation!(user, evaluation.id), key: key}
    end

    test "says the judge failed, not the model", %{conn: conn, evaluation: evaluation} do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # Errored runs are hidden behind a toggle; when every run errored the
      # page has nothing else to show, so the batch opens expanded.
      html = render(live)

      assert html =~ "Judge failed"
      # The answer that was paid for is on the page, not one click away in
      # the log viewer.
      assert html =~ "Hello from test-model"
    end

    test "offers to retry only the failed runs, naming what it will redo", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#retry-failed-button")
      assert render(live) =~ "re-judge"

      # Give the evaluation a judge that can score, then retry.
      evaluation
      |> Ecto.Changeset.change(judge_model: "judge-model")
      |> Repo.update!()

      live |> element("#retry-failed-button") |> render_click()

      run =
        Repo.one!(
          from(r in EvaluationRun,
            where: r.evaluation_id == ^evaluation.id and is_nil(r.superseded_at)
          )
        )

      assert run.status == "completed"
      assert is_integer(run.score)

      _ = user
    end

    test "a retry counts against the runs being retried, not the whole batch", %{
      conn: conn,
      evaluation: evaluation
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # A retry re-runs rows that already exist, so counting against the
      # plan reads "1 of 1" from the first second and the bar never moves.
      # The denominator is what is actually being retried.
      send(live.pid, {:retry_started, 4})
      assert render(live) =~ "0 of 4"

      send(live.pid, {:benchmark_progress, {:ok, :whatever}})
      send(live.pid, {:benchmark_progress, {:ok, :whatever}})

      html = render(live)
      assert html =~ "2 of 4"
      assert has_element?(live, "#eval-progress progress[value='2'][max='4']")
    end

    test "shows the benchmark's own status when nothing completed", %{
      conn: conn,
      evaluation: evaluation
    } do
      {:ok, _live, html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert html =~ "eval-status"
    end
  end

  test "warns when the judge and a candidate share one provider key", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Shared key",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: [
          %{
            "provider_key_id" => key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 3
      })

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # Judging and generating on one account is how a benchmark rate-limits
    # itself, and it is knowable before the run rather than after.
    assert has_element?(live, "#shared-key-warning")
    assert render(live) =~ "Key 1"
  end

  describe "a long rubric" do
    setup %{user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user)
      log = LogsFixtures.log_fixture(router)

      criteria =
        Enum.map_join(1..40, "\n", fn n ->
          "#{n}. A hard rule the reply must obey, stated at length so the rubric is genuinely long."
        end)

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Long rubric",
          criteria: criteria,
          judge_model: "test-model",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ]
        })

      %{evaluation: evaluation}
    end

    test "is clamped until asked for, so it cannot set the row's height", %{
      conn: conn,
      evaluation: evaluation
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#criteria-body.line-clamp-6")
      assert has_element?(live, "#toggle-criteria")

      html = live |> element("#toggle-criteria") |> render_click()

      refute has_element?(live, "#criteria-body.line-clamp-6")
      assert html =~ "Show less"
    end

    test "a short rubric gets no toggle at all", %{conn: conn, user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Short rubric key"})
      log = LogsFixtures.log_fixture(router)

      {:ok, short} =
        Evaluations.create_evaluation(user, log, %{
          name: "Short rubric",
          criteria: "Answer directly.",
          judge_model: "test-model",
          judge_provider_key_id: key.id,
          candidate_targets: []
        })

      {:ok, live, _html} = live(conn, ~p"/evals/#{short.id}")

      refute has_element?(live, "#toggle-criteria")
      refute has_element?(live, "#criteria-body.line-clamp-6")
    end

    test "the two panels are not stretched to a common height", %{
      conn: conn,
      evaluation: evaluation
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # Grid items stretch by default, so the rubric's height became the
      # chart's height and left the plot floating in whitespace.
      assert has_element?(live, "#eval-panels.items-start")
    end
  end

  test "the score chart says why it is empty rather than drawing bare axes", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Nothing scored",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    # A ranked target with no scored run: rankings exist, the chart has
    # nothing to plot.
    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "failed",
      failure_stage: "candidate",
      candidate_provider: "test_provider",
      candidate_model: "test-model",
      repetition: 1
    })
    |> Repo.insert!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    refute has_element?(live, "#quality-consistency-chart svg")
    assert has_element?(live, "#score-trend", "No run has been scored")
  end

  describe "a batch where most runs errored" do
    setup %{user: user} do
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Mixed key"})
      log = LogsFixtures.log_fixture(router)

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Mostly errors",
          criteria: "Be useful",
          judge_model: "test-model",
          judge_provider_key_id: key.id,
          candidate_targets: [
            %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
          ]
        })

      batch = Ecto.UUID.generate()
      evaluation = evaluation |> Ecto.Changeset.change(last_batch_id: batch) |> Repo.update!()

      insert = fn attrs ->
        %EvaluationRun{}
        |> EvaluationRun.changeset(
          Map.merge(
            %{
              evaluation_id: evaluation.id,
              batch_id: batch,
              candidate_provider: "test_provider",
              candidate_model: "test-model"
            },
            attrs
          )
        )
        |> Repo.insert!()
      end

      scored =
        insert.(%{
          status: "completed",
          score: 2,
          repetition: 1,
          summary: "Missing markers",
          issues: ["No TITLE marker", "Prose before HTML"],
          criterion_scores: %{"accuracy" => 35, "completeness" => 30},
          candidate_output: "the answer text",
          reasoning: "Checked each rule."
        })

      errored =
        insert.(%{
          status: "failed",
          failure_stage: "candidate",
          repetition: 2,
          error: "Candidate call rate limited"
        })

      %{evaluation: evaluation, scored: scored, errored: errored}
    end

    test "the errors are on the page without hunting for a toggle", %{
      conn: conn,
      evaluation: evaluation,
      errored: errored
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # 16 of 18 failing is the batch's headline, not a footnote behind a
      # control that reads like an advanced option.
      assert has_element?(live, "#run-#{errored.id}")
      assert render(live) =~ "Candidate call rate limited"
    end

    test "a scored run's detail is collapsed, so a long batch stays scannable", %{
      conn: conn,
      evaluation: evaluation,
      scored: scored
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # Criterion bars, issue lists, the answer and the judge's reasoning are
      # each screens tall; eighteen runs of them is not a page anyone reads.
      assert has_element?(live, "#run-#{scored.id} details#run-detail-#{scored.id}")
      assert has_element?(live, "#run-detail-#{scored.id} li", "No TITLE marker")

      # The one-line identity stays visible without expanding anything.
      assert has_element?(live, "#run-#{scored.id}", "Missing markers")
    end

    test "failures are summarised by provider and cause, not one row per run", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      # Three more failures on one provider for one reason: the digest says
      # that once, with a count.
      for repetition <- 3..5 do
        %EvaluationRun{}
        |> EvaluationRun.changeset(%{
          evaluation_id: evaluation.id,
          batch_id: evaluation.last_batch_id,
          status: "failed",
          failure_stage: "candidate",
          candidate_provider: "moonshot",
          candidate_model: "kimi",
          repetition: repetition,
          error: "You've reached your usage limit for this billing cycle"
        })
        |> Repo.insert!()
      end

      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#failure-digest", "moonshot")
      assert has_element?(live, "#failure-digest", "out of quota")
      assert has_element?(live, "#failure-digest li", "3")
      _ = user
    end

    test "accounts for every planned run, including the ones that never started", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      # A benchmark that dies partway leaves three populations, and the
      # digest used to describe only the first: runs that failed, runs stuck
      # mid-flight, and runs that never started at all. The last is why a
      # model can be configured as a candidate and appear nowhere on the
      # page — the one question "why did nothing happen for glm-5?" asks.
      evaluation
      |> Ecto.Changeset.change(
        repetitions: 3,
        candidate_targets: [
          %{"provider_key_id" => Ecto.UUID.generate(), "provider" => "zai", "model" => "glm-5"},
          %{
            "provider_key_id" => Ecto.UUID.generate(),
            "provider" => "moonshot",
            "model" => "kimi-k2.7-code"
          }
        ]
      )
      |> Repo.update!()

      # One stuck row for glm-5; kimi never got a row at all.
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        batch_id: evaluation.last_batch_id,
        status: "running",
        candidate_provider: "zai",
        candidate_model: "glm-5",
        repetition: 1
      })
      |> Repo.insert!()

      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#failure-digest", "Interrupted")
      assert has_element?(live, "#failure-digest", "Never started")
      assert has_element?(live, "#failure-digest", "kimi-k2.7-code")
    end

    test "marks the affected candidate in the list, not only in the banner", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      key = DodoRouter.Providers.get_provider_key!(user, evaluation.judge_provider_key_id)
      DodoRouter.Providers.apply_health(key.id, :quota, "usage limit reached")

      evaluation
      |> Ecto.Changeset.change(
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "model-a"}
        ]
      )
      |> Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      # The banner says it once; the list is where the eye goes to answer
      # "which of these six is the problem".
      assert has_element?(live, "#eval-candidates", "out of quota")
    end

    test "a key the proxy already knows is exhausted is called out before running", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      key = DodoRouter.Providers.get_provider_key!(user, evaluation.judge_provider_key_id)
      DodoRouter.Providers.apply_health(key.id, :quota, "usage limit reached")

      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#key-preflight", "out of quota")

      # And starting it is refused rather than half-run.
      live |> form("#run-eval-form") |> render_submit()
      assert render(live) =~ "Not starting"
    end

    test "a running benchmark can be cancelled from the page", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      evaluation
      |> Ecto.Changeset.change(benchmark_status: "running")
      |> DodoRouter.Repo.update!()

      test_pid = self()

      spawn(fn ->
        Registry.register(DodoRouter.EvaluationRegistry, evaluation.id, nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

      assert_receive :registered

      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")
      assert has_element?(live, "#cancel-eval-button")

      live |> element("#cancel-eval-button") |> render_click()

      assert DodoRouter.Evaluations.get_evaluation!(user, evaluation.id).benchmark_status ==
               "cancelled"
    end

    test "Run again accepts a repetitions override", %{
      conn: conn,
      user: user,
      evaluation: evaluation
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      assert has_element?(live, "#run-repetitions")

      live |> form("#run-eval-form", %{"repetitions" => "5"}) |> render_submit()

      assert DodoRouter.Evaluations.get_evaluation!(user, evaluation.id).repetitions == 5
    end

    test "errored runs can still be hidden when only the scores matter", %{
      conn: conn,
      evaluation: evaluation,
      errored: errored,
      scored: scored
    } do
      {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

      live |> element("button[phx-click='toggle_errored']") |> render_click()

      refute has_element?(live, "#run-#{errored.id}")
      assert has_element?(live, "#run-#{scored.id}")
    end
  end

  test "says which models it is set up to run, even before any of them have", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Configured but unrun",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        repetitions: 3,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "model-a"},
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "model-b"}
        ]
      })

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # The rankings table only lists models that produced runs, so an
    # evaluation that never ran — or died halfway — showed nothing at all
    # about what it was set up to measure.
    assert has_element?(live, "#eval-candidates", "model-a")
    assert has_element?(live, "#eval-candidates", "model-b")
    assert has_element?(live, "#eval-candidates", "Key 1")
    assert render(live) =~ "6 runs"
  end

  test "an earlier attempt stays reachable under the run that replaced it", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Retried",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    batch = Ecto.UUID.generate()
    evaluation = evaluation |> Ecto.Changeset.change(last_batch_id: batch) |> Repo.update!()

    live_run =
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        batch_id: batch,
        status: "completed",
        score: 80,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        repetition: 1
      })
      |> Repo.insert!()

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "failed",
      failure_stage: "judge",
      candidate_provider: "test_provider",
      candidate_model: "test-model",
      repetition: 1,
      error: "Judge call failed — anthropic rate limited",
      superseded_at: DateTime.utc_now(),
      superseded_by_id: live_run.id
    })
    |> Repo.insert!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    # One row in the batch, not two — but the failure it replaced is still
    # on the page rather than overwritten.
    assert render(live) =~ "1 runs"
    assert has_element?(live, "#run-attempts-#{live_run.id}", "rate limited")
  end

  test "a benchmark that died mid-run stops claiming to be running", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Interrupted",
        criteria: "Be useful",
        judge_model: "test-model",
        judge_provider_key_id: key.id,
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    # A restart, a crash, or a status write that never landed leaves this
    # behind. No process is running, so the page must not show a spinner
    # and a progress bar forever.
    evaluation |> Ecto.Changeset.change(benchmark_status: "running") |> Repo.update!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    refute has_element?(live, "#eval-progress")
    assert has_element?(live, "#eval-status", "interrupted")
    refute has_element?(live, "#run-eval-button[disabled]")
  end

  test "hands the agent surface to the user as a runnable command", %{conn: conn, user: user} do
    {_router, _api_key} = RoutersFixtures.router_fixture(user)

    {:ok, live, _html} = live(conn, ~p"/evals")

    # The command is the only way an agent learns this surface exists. It names
    # no router because MCP is router-unscoped — the agent asks which routers it
    # reaches once connected, so there is no slug to get wrong here.
    assert has_element?(live, "#agent-access", "claude mcp add")
    assert has_element?(live, "#agent-access", "/mcp")
  end

  test "benchmarks a recording in one motion", %{conn: conn, user: user} do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    {:ok, recording} = DodoRouter.Recordings.start_recording(router, %{name: "Prod capture"})

    body = fn text ->
      Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => text}]})
    end

    log1 =
      LogsFixtures.log_fixture(router, %{
        recording_id: recording.id,
        request_body: body.("one"),
        final_model: "test-model",
        attempted_steps: [
          %{"status" => "success", "provider_key_id" => provider_key.id, "model" => "test-model"}
        ]
      })

    log2 =
      LogsFixtures.log_fixture(router, %{recording_id: recording.id, request_body: body.("two")})

    # Captured but not replayable: excluded from the sample, not fatal.
    LogsFixtures.log_fixture(router, %{recording_id: recording.id})

    {:ok, live, html} =
      live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}/evals/new")

    # The source panel says what is being benchmarked and what fell out.
    assert has_element?(live, "#eval-recording-source", "Prod capture")
    assert html =~ "of 3 captured"
    assert has_element?(live, "#planned-runs-note")

    # The incumbent that served the capture is preselected as a candidate.
    assert has_element?(live, "#selected-candidates", "test-model")

    live
    |> form("#eval-form", %{"evaluation" => %{"judge_key" => provider_key.id}})
    |> render_change()

    live
    |> form("#eval-form", %{
      "evaluation" => %{
        "name" => "Recording benchmark",
        "criteria" => "Answer accurately",
        "candidate_target_values" => ["#{provider_key.id}|test-model"],
        "repetitions" => "1",
        "judge_key" => provider_key.id,
        "judge_target" => "#{provider_key.id}|test-model"
      }
    })
    |> render_submit()

    {path, _flash} = assert_redirect(live)
    assert String.starts_with?(path, "/evals/")

    evaluation_id = path |> String.trim_leading("/evals/") |> URI.parse() |> Map.fetch!(:path)
    evaluation = Evaluations.get_evaluation!(user, evaluation_id)

    assert evaluation.recording_id == recording.id
    assert Enum.sort(evaluation.source_log_ids) == Enum.sort([log1.id, log2.id])
    # 2 source logs x 1 candidate x 1 repetition, run by the save action.
    assert length(evaluation.runs) == 2
  end

  test "multi-log rankings expose the weakest request and expand per source", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    body = fn text ->
      Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => text}]})
    end

    log1 = LogsFixtures.log_fixture(router, %{request_body: body.("one")})
    log2 = LogsFixtures.log_fixture(router, %{request_body: body.("two")})

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log1, %{
        name: "Per-source UI",
        criteria: "Be useful",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        source_log_ids: [log1.id, log2.id]
      })

    for {source_log, score} <- [{log1, 90}, {log2, 30}] do
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        evaluation_id: evaluation.id,
        status: "completed",
        score: score,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        source_log_id: source_log.id
      })
      |> Repo.insert!()
    end

    {:ok, live, html} = live(conn, ~p"/evals/#{evaluation.id}")

    # The weakest request's average is visible without expanding anything.
    assert html =~ "Weakest request"
    assert has_element?(live, "button[phx-click='toggle_ranking_sources']", "30")

    html = live |> element("button[phx-click='toggle_ranking_sources']") |> render_click()
    assert html =~ "Per source request, weakest first"
    assert html =~ String.slice(log2.id, 0, 8)
  end

  test "a recording-based benchmark shows the monthly projection panel", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    {:ok, recording} = DodoRouter.Recordings.start_recording(router, %{name: "Rate capture"})

    recording =
      recording
      |> Ecto.Changeset.change(
        started_at: DateTime.add(DateTime.utc_now(), -15, :day),
        stopped_at: DateTime.utc_now(),
        status: "stopped"
      )
      |> Repo.update!()

    log =
      LogsFixtures.log_fixture(router, %{
        recording_id: recording.id,
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}),
        list_cost_usd: Decimal.new("1.00")
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Projection UI",
        criteria: "Be useful",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "cheap"
          }
        ],
        recording_id: recording.id
      })

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "completed",
      score: 90,
      candidate_provider: "test_provider",
      candidate_model: "cheap",
      candidate_list_cost_usd: Decimal.new("0.25")
    })
    |> Repo.insert!()

    {:ok, live, html} = live(conn, ~p"/evals/#{evaluation.id}")

    assert has_element?(live, "#savings-projection")
    assert html =~ "As served, this traffic projects to"
    assert html =~ "Savings /month"
  end

  test "a verdict is applied from the ranking row and stays revertible", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    incumbent_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Incumbent key"})
    candidate_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Candidate key"})

    {:ok, step} =
      DodoRouter.Routers.create_routing_step(router, %{
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
        name: "Apply flow",
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

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      status: "completed",
      score: 90,
      candidate_provider: "test_provider",
      candidate_model: "cheap-model"
    })
    |> Repo.insert!()

    {:ok, live, _html} = live(conn, ~p"/evals/#{evaluation.id}")

    html = live |> element("button[phx-click='apply_verdict']") |> render_click()
    assert html =~ "Routing updated"
    assert has_element?(live, "#applied-changes", "cheap-model")

    updated = DodoRouter.Routers.get_routing_step!(router, step.id)
    assert updated.model == "cheap-model"
    assert updated.provider_key_id == candidate_key.id

    # Keep the decision honest: monitoring starts from the applied change
    # and the panel appears with the benchmark's baseline.
    html = live |> element("button[phx-click='enable_monitor']") |> render_click()
    assert html =~ "Monitoring on"
    assert has_element?(live, "#eval-monitor", "Live monitoring")
    assert has_element?(live, "#eval-monitor", "cheap-model")

    html = live |> element("#toggle-monitor") |> render_click()
    assert html =~ "Monitoring paused"
    assert has_element?(live, "#eval-monitor", "paused")

    html = live |> element("button[phx-click='revert_verdict']") |> render_click()
    assert html =~ "Routing reverted"
    assert has_element?(live, "#applied-changes", "reverted")

    reverted = DodoRouter.Routers.get_routing_step!(router, step.id)
    assert reverted.model == "incumbent-model"
    assert reverted.provider_key_id == incumbent_key.id
  end

  test "a recording with nothing replayable bounces back with the reason", %{
    conn: conn,
    user: user
  } do
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    {:ok, recording} = DodoRouter.Recordings.start_recording(router)
    LogsFixtures.log_fixture(router, %{recording_id: recording.id})

    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/routers/#{router.id}/recordings/#{recording.id}/evals/new")

    assert to == "/routers/#{router.id}/recordings/#{recording.id}"
    assert flash["error"] =~ "can be replayed"
  end

  test "someone else's recording is not a benchmark entry point", %{conn: conn} do
    other = DodoRouter.AccountsFixtures.user_fixture()
    {other_router, _} = RoutersFixtures.router_fixture(other)
    {:ok, foreign} = DodoRouter.Recordings.start_recording(other_router)

    # The router fetch is scoped first, so a foreign router 404s outright.
    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/routers/#{other_router.id}/recordings/#{foreign.id}/evals/new")
    end
  end
end
