defmodule DodoRouter.EvaluationsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Evaluations
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures
  alias DodoRouter.AccountsFixtures

  test "creates a user-owned evaluation from a log and aggregates runs" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    assert {:ok, evaluation} =
             Evaluations.create_evaluation(user, log, %{
               name: "Helpful answer",
               criteria: "Answer directly and accurately",
               judge_model: "test-model",
               judge_provider_key_id: provider_key.id,
               candidate_targets: [
                 %{
                   "provider_key_id" => provider_key.id,
                   "provider" => "test_provider",
                   "model" => "test-model"
                 }
               ],
               repetitions: 3
             })

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert loaded.request_log.id == log.id

    assert Evaluations.summary(loaded) == %{
             runs: 0,
             completed: 0,
             failed: 0,
             average: nil,
             best: nil,
             avg_latency: nil,
             pass_rate: nil
           }
  end

  test "parses and clamps a structured judge response" do
    raw = """
    ```json
    {"score": 104, "passed": true, "summary": "Strong answer", "criterion_scores": {"accuracy": 97}, "issues": []}
    ```
    """

    assert {:ok, result} = Evaluations.parse_judgement(raw)
    assert result.score == 100
    assert result.criterion_scores == %{"accuracy" => 97}
  end

  test "rejects an unstructured judge response" do
    assert {:error, _message} = Evaluations.parse_judgement("looks good to me")
  end

  test "falls back to the existing app task supervisor during a hot reload" do
    assert Evaluations.available_task_supervisor(DodoRouter.MissingEvaluationTaskSupervisor) ==
             DodoRouter.KeyHealthTaskSupervisor
  end

  test "judge requests do not force a provider-incompatible temperature" do
    evaluation = %DodoRouter.Logs.Evaluation{
      judge_model: "k2p5",
      criteria: "Be correct",
      request_log: %DodoRouter.Logs.RequestLog{request_body: "{}"}
    }

    candidate = %DodoRouter.Logs.RequestLog{response_body: "{}"}

    refute Map.has_key?(Evaluations.judge_request(evaluation, candidate), "temperature")
  end

  test "formats all-providers-failed proxy errors without crashing" do
    attempts = [%{provider: "moonshot", error: "bad_request", http_status: 400}]

    assert Evaluations.proxy_error_message({:error, :all_providers_failed, attempts}) =~
             "all_providers_failed"
  end

  test "provider error logs are not valid candidate answers" do
    refute Evaluations.candidate_successful?(%DodoRouter.Logs.RequestLog{
             status: "error",
             http_status: 400,
             response_body: Jason.encode!(%{"detail" => "model is not supported"})
           })

    assert Evaluations.candidate_successful?(%DodoRouter.Logs.RequestLog{status: "success"})
    assert Evaluations.candidate_successful?(%DodoRouter.Logs.RequestLog{status: "fallback"})
  end

  test "generates every candidate repetition before judging it" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{
            "model" => "original-model",
            "messages" => [%{"role" => "user", "content" => "Say hello"}]
          }),
        response_body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => "Original"}}]})
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Greeting benchmark",
        criteria: "Say hello",
        judge_model: "test-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 2
      })

    assert {:ok, results} = Evaluations.run(user, evaluation)
    assert length(results) == 2

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert length(loaded.runs) == 2
    assert Enum.all?(loaded.runs, &(&1.candidate_model == "test-model"))
    assert Enum.all?(loaded.runs, &is_binary(&1.candidate_output))
  end
end
