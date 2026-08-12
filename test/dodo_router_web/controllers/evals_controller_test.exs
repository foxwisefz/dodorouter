defmodule DodoRouterWeb.EvalsControllerTest do
  use DodoRouterWeb.ConnCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.EvaluationRun
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Repo
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "prod key"})

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{
            "model" => "test-model",
            "messages" => [%{"role" => "user", "content" => "How long is the refund window?"}]
          })
      })

    %{user: user, router: router, api_key: api_key, provider_key: provider_key, log: log}
  end

  defp auth(conn, api_key), do: put_req_header(conn, "authorization", "Bearer #{api_key}")

  defp create_params(log, provider_key, overrides \\ %{}) do
    Map.merge(
      %{
        "request_log_id" => log.id,
        "name" => "Support reply quality",
        "criteria" => "States the 30 day refund window. Under 120 words.",
        "judge" => %{"provider_key_id" => provider_key.id, "model" => "test-model"},
        "candidates" => [%{"provider_key_id" => provider_key.id, "model" => "test-model"}],
        "repetitions" => 1
      },
      overrides
    )
  end

  describe "GET /r/:router_slug/agent" do
    test "hands a caller with only a key the whole loop", %{
      conn: conn,
      router: router,
      api_key: api_key
    } do
      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/agent")

      body = json_response(conn, 200)
      assert body["router"]["slug"] == router.slug
      # The guide is addressed to this router, not to a placeholder.
      assert body["guide"] =~ "/r/#{router.slug}"
      refute body["guide"] =~ "{{BASE}}"

      paths = Enum.map(body["endpoints"], & &1["path"])
      assert "/logs" in paths
      assert "/evals" in paths
      assert "/evals/:id/run" in paths
      assert Enum.all?(body["endpoints"], &String.contains?(&1["url"], "/r/#{router.slug}"))
    end

    test "requires the router API key", %{conn: conn, router: router} do
      assert json_response(get(conn, "/r/#{router.slug}/agent"), 401)
    end
  end

  describe "GET /r/:router_slug/evals/targets" do
    test "lists the keys and models a candidate can name", %{
      conn: conn,
      router: router,
      api_key: api_key,
      provider_key: provider_key
    } do
      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals/targets")

      assert %{"data" => [target]} = json_response(conn, 200)
      assert target["provider_key_id"] == provider_key.id
      assert target["label"] == "prod key"
      assert target["provider"] == "test_provider"
      assert Enum.any?(target["models"], &(&1["id"] == "test-model"))
    end

    test "is not read as an evaluation id", %{conn: conn, router: router, api_key: api_key} do
      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals/targets")
      assert Map.has_key?(json_response(conn, 200), "data")
    end
  end

  describe "POST /r/:router_slug/evals" do
    test "creates an evaluation and derives the provider from the key", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      conn =
        conn
        |> auth(api_key)
        |> post("/r/#{router.slug}/evals", create_params(log, provider_key))

      body = json_response(conn, 201)
      assert body["name"] == "Support reply quality"
      assert body["status"] == "draft"
      assert body["request_log_id"] == log.id
      assert body["judge"]["model"] == "test-model"
      assert body["summary"]["runs"] == 0

      evaluation = Evaluations.get_evaluation!(user, body["id"])

      # The caller never sends a provider name; the pair routing is keyed on
      # is derived from the key so the two can't disagree.
      assert [%{"provider" => "test_provider", "model" => "test-model"}] =
               evaluation.candidate_targets
    end

    test "rejects a provider key the caller does not own", %{
      conn: conn,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      stranger = AccountsFixtures.user_fixture()
      stranger_key = ProvidersFixtures.provider_key_fixture(stranger)

      conn =
        conn
        |> auth(api_key)
        |> post(
          "/r/#{router.slug}/evals",
          create_params(log, provider_key, %{
            "candidates" => [%{"provider_key_id" => stranger_key.id, "model" => "test-model"}]
          })
        )

      assert json_response(conn, 422)["error"]["message"] =~ "not one of your provider keys"
    end

    test "refuses a log that cannot be replayed, with the reason", %{
      conn: conn,
      router: router,
      api_key: api_key,
      provider_key: provider_key
    } do
      unreplayable = LogsFixtures.log_fixture(router)

      conn =
        conn
        |> auth(api_key)
        |> post("/r/#{router.slug}/evals", create_params(unreplayable, provider_key))

      assert json_response(conn, 422)["error"]["message"] =~ "not valid JSON"
    end

    test "404s for a log on another router", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key
    } do
      {other_router, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other_router)

      conn =
        conn
        |> auth(api_key)
        |> post("/r/#{router.slug}/evals", create_params(other_log, provider_key))

      assert json_response(conn, 404)["error"]["type"] == "not_found"
    end

    test "reports changeset errors per field", %{
      conn: conn,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      conn =
        conn
        |> auth(api_key)
        |> post(
          "/r/#{router.slug}/evals",
          create_params(log, provider_key, %{"name" => "", "repetitions" => 50})
        )

      details = json_response(conn, 422)["error"]["details"]
      assert details["name"]
      assert details["repetitions"]
    end

    test "run=true executes the benchmark and records a run per repetition", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      conn =
        conn
        |> auth(api_key)
        |> post(
          "/r/#{router.slug}/evals",
          create_params(log, provider_key, %{"run" => true, "repetitions" => 2})
        )

      body = json_response(conn, 201)
      # BackgroundTask settles in :test, so the batch is finished by now.
      refute body["status"] in ["draft", "running"]
      assert body["summary"]["runs"] == 2

      evaluation = Evaluations.get_evaluation!(user, body["id"])
      assert length(evaluation.runs) == 2
      assert Enum.all?(evaluation.runs, &(&1.batch_id == evaluation.last_batch_id))

      # The candidate really was replayed through the proxy: each run links
      # the log its answer came from.
      assert Enum.all?(evaluation.runs, & &1.candidate_log_id)
    end
  end

  describe "GET /r/:router_slug/evals/:id" do
    test "ranks the candidates on score, latency and price", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      evaluation = completed_evaluation(user, log, provider_key)

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals/#{evaluation.id}")

      body = json_response(conn, 200)
      assert body["summary"]["completed"] == 2
      assert body["summary"]["average"] == 75

      # Best average first, so the comparison reads top-down.
      assert [strong, cheap] = body["rankings"]
      assert strong["model"] == "strong-model"
      assert strong["avg_score"] == 90
      assert strong["avg_cost_usd"] == 0.01
      assert cheap["model"] == "cheap-model"
      assert cheap["avg_score"] == 60
      assert cheap["avg_cost_usd"] == 0.001

      # The judge's own report on the rubric travels with the scores, so a
      # thin rubric is visible next to the numbers it produced.
      assert body["rubric_feedback"]["flagged"] == 1
      assert "no length limit stated" in body["rubric_feedback"]["gaps"]

      # The answer itself is inlined far enough to read at a glance.
      assert Enum.any?(body["runs"], &(&1["output_preview"] == "A cheap answer"))
    end

    test "only counts the latest batch", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      evaluation = completed_evaluation(user, log, provider_key)

      stale_batch = Ecto.UUID.generate()
      insert_run(evaluation, stale_batch, "old-model", 5, Decimal.new("0.5"), [])

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals/#{evaluation.id}")

      models = Enum.map(json_response(conn, 200)["rankings"], & &1["model"])
      refute "old-model" in models
    end

    test "404s for an evaluation anchored to another router's log", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key
    } do
      {other_router, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other_router)
      evaluation = completed_evaluation(user, other_log, provider_key)

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals/#{evaluation.id}")

      assert json_response(conn, 404)["error"]["type"] == "not_found"
    end
  end

  describe "GET /r/:router_slug/evals" do
    test "lists only this router's evaluations", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      mine = completed_evaluation(user, log, provider_key)

      {other_router, _key} = RoutersFixtures.router_fixture(user)
      other_log = LogsFixtures.log_fixture(other_router)
      _theirs = completed_evaluation(user, other_log, provider_key)

      conn = conn |> auth(api_key) |> get("/r/#{router.slug}/evals")

      assert %{"data" => [listed]} = json_response(conn, 200)
      assert listed["id"] == mine.id
      assert listed["run_count"] == 3
    end
  end

  describe "POST /r/:router_slug/evals/:id/run" do
    test "starts the benchmark and reports how much work it queued", %{
      conn: conn,
      user: user,
      router: router,
      api_key: api_key,
      provider_key: provider_key,
      log: log
    } do
      {:ok, evaluation} = create_evaluation(user, log, provider_key)

      conn = conn |> auth(api_key) |> post("/r/#{router.slug}/evals/#{evaluation.id}/run")

      body = json_response(conn, 202)
      assert body["evaluation_id"] == evaluation.id
      assert body["runs_queued"] == 1
      refute body["running"]

      assert length(Evaluations.get_evaluation!(user, evaluation.id).runs) == 1
    end

    test "404s for an unknown evaluation", %{conn: conn, router: router, api_key: api_key} do
      conn =
        conn |> auth(api_key) |> post("/r/#{router.slug}/evals/#{Ecto.UUID.generate()}/run")

      assert json_response(conn, 404)["error"]["type"] == "not_found"
    end
  end

  ## Helpers

  defp create_evaluation(user, log, provider_key) do
    Evaluations.create_evaluation(user, log, %{
      name: "Support reply quality",
      criteria: "States the 30 day refund window",
      judge_model: "test-model",
      judge_provider_key_id: provider_key.id,
      candidate_targets: [
        %{
          "provider_key_id" => provider_key.id,
          "provider" => "test_provider",
          "model" => "test-model"
        }
      ],
      repetitions: 1
    })
  end

  # A finished batch, written directly: the test provider's judge can't
  # return a parseable score, and these assertions are about how a finished
  # benchmark is reported, not about how it is produced.
  defp completed_evaluation(user, log, provider_key) do
    {:ok, evaluation} = create_evaluation(user, log, provider_key)

    batch_id = Ecto.UUID.generate()
    evaluation = evaluation |> Ecto.Changeset.change(last_batch_id: batch_id) |> Repo.update!()

    insert_run(evaluation, batch_id, "strong-model", 90, Decimal.new("0.01"), [])

    insert_run(evaluation, batch_id, "cheap-model", 60, Decimal.new("0.001"), [
      "no length limit stated"
    ])

    insert_run(evaluation, batch_id, "cheap-model", nil, Decimal.new("0.001"), [],
      status: "failed"
    )

    evaluation
  end

  defp insert_run(evaluation, batch_id, model, score, cost, gaps, opts \\ []) do
    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      judge_prompt_version: "v4",
      status: Keyword.get(opts, :status, "completed"),
      score: score,
      summary: "judged",
      rubric_gaps: gaps,
      batch_id: batch_id,
      candidate_provider: "test_provider",
      candidate_model: model,
      candidate_latency_ms: 120,
      candidate_cost_usd: cost,
      candidate_list_cost_usd: cost,
      candidate_output: "A #{String.replace(model, "-model", "")} answer",
      repetition: 1
    })
    |> Repo.insert!()
  end
end
