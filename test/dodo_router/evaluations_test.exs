defmodule DodoRouter.EvaluationsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.{Evaluation, EvaluationRun}
  alias DodoRouter.Logs.RequestLog
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
             total_cost_usd: nil,
             total_list_cost_usd: nil
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
    evaluation = %Evaluation{
      judge_model: "k2p5",
      criteria: "Be correct",
      request_log: %RequestLog{request_body: "{}"}
    }

    refute Map.has_key?(Evaluations.judge_request(evaluation, "An answer"), "temperature")
  end

  test "judge prompt is blind to candidate identity and provider metadata" do
    evaluation = %Evaluation{
      judge_model: "judge-model",
      criteria: "Be correct",
      request_log: %RequestLog{
        request_body:
          Jason.encode!(%{
            "model" => "secret-candidate-model",
            "temperature" => 0.2,
            "messages" => [%{"role" => "user", "content" => "What is 2+2?"}]
          })
      }
    }

    request = Evaluations.judge_request(evaluation, "The answer is 4.")
    [_system, %{"content" => prompt}] = request["messages"]

    assert prompt =~ "What is 2+2?"
    assert prompt =~ "The answer is 4."
    refute prompt =~ "secret-candidate-model"
    refute prompt =~ "temperature"
  end

  test "judge prompt truncates oversized source content" do
    long = String.duplicate("a", 300_000)

    evaluation = %Evaluation{
      judge_model: "judge-model",
      criteria: "Be correct",
      request_log: %RequestLog{
        request_body:
          Jason.encode!(%{
            "model" => "m",
            "messages" => [%{"role" => "user", "content" => long}]
          })
      }
    }

    request = Evaluations.judge_request(evaluation, long)
    [_system, %{"content" => prompt}] = request["messages"]

    assert prompt =~ "truncated"
    assert String.length(prompt) < 150_000
  end

  test "tolerates extra judge fields like the retired passed verdict" do
    assert {:ok, judgement} =
             Evaluations.parse_judgement(~s({"score": 85, "passed": true, "summary": "solid"}))

    refute Map.has_key?(judgement, :passed)
  end

  test "extracts the judge's reasoning and rubric gaps" do
    raw =
      Jason.encode!(%{
        "reasoning" => "Criterion one is met because the reply greets the user.",
        "score" => 88,
        "summary" => "Good",
        "rubric_gaps" => ["Criteria do not say whether brevity matters", 42]
      })

    assert {:ok, judgement} = Evaluations.parse_judgement(raw)
    assert judgement.reasoning =~ "greets the user"
    # Non-string entries from a sloppy judge are dropped, like issues.
    assert judgement.rubric_gaps == ["Criteria do not say whether brevity matters"]

    # Judges on the old contract yield empty feedback, not crashes.
    assert {:ok, legacy} = Evaluations.parse_judgement(~s({"score": 70, "summary": "ok"}))
    assert legacy.reasoning == nil
    assert legacy.rubric_gaps == []
  end

  test "judge prompt demands reasoning before the score and invites rubric feedback" do
    evaluation = %Evaluation{
      judge_model: "judge-model",
      criteria: "Be correct",
      request_log: %RequestLog{request_body: "{}"}
    }

    [_system, %{"content" => prompt}] =
      Evaluations.judge_request(evaluation, "An answer")["messages"]

    assert prompt =~ "reasoning"
    assert prompt =~ "rubric_gaps"
  end

  test "summarizes rubric gaps across a batch" do
    runs = [
      %EvaluationRun{status: "completed", rubric_gaps: ["No length guidance", "Tone undefined"]},
      %EvaluationRun{status: "completed", rubric_gaps: ["No length guidance"]},
      %EvaluationRun{status: "completed", rubric_gaps: []},
      %EvaluationRun{status: "failed", rubric_gaps: []}
    ]

    assert %{flagged: 2, scored: 3, gaps: gaps} = Evaluations.rubric_feedback(runs)
    assert "No length guidance" in gaps
    assert "Tone undefined" in gaps
    assert length(gaps) == 2
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

  describe "tool-calling candidates" do
    # A tool call IS the answer for a tool-calling request: the model that
    # calls record_call_type with the right arguments did the task, and the
    # OpenAI shape puts an empty string in content when it does.
    @tool_call_response Jason.encode!(%{
                          "choices" => [
                            %{
                              "finish_reason" => "tool_calls",
                              "index" => 0,
                              "message" => %{
                                "content" => "",
                                "role" => "assistant",
                                "tool_calls" => [
                                  %{
                                    "id" => "toolu_01WKh8zeBYSE6yHcQWSRC2rX",
                                    "type" => "function",
                                    "function" => %{
                                      "name" => "record_call_type",
                                      "arguments" => %{
                                        "call_type" => "Vendor",
                                        "customer_company" => "",
                                        "reasoning" => "Ken Lee is pitching to SketchDeck."
                                      }
                                    }
                                  }
                                ]
                              }
                            }
                          ]
                        })

    test "a tool call is the candidate's answer, not an empty response" do
      content = Evaluations.extract_message_content(@tool_call_response)

      assert content =~ "record_call_type"
      assert content =~ "Vendor"
      assert content =~ "Ken Lee is pitching to SketchDeck."
    end

    test "arguments serialized as a JSON string survive too" do
      response =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => nil,
                "tool_calls" => [
                  %{
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "arguments" => ~s({"city":"Lisbon"})
                    }
                  }
                ]
              }
            }
          ]
        })

      content = Evaluations.extract_message_content(response)

      assert content =~ "get_weather"
      assert content =~ "Lisbon"
    end

    test "text alongside a tool call keeps both" do
      response =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "Let me look that up.",
                "tool_calls" => [
                  %{
                    "type" => "function",
                    "function" => %{"name" => "search", "arguments" => "{}"}
                  }
                ]
              }
            }
          ]
        })

      content = Evaluations.extract_message_content(response)

      assert content =~ "Let me look that up."
      assert content =~ "search"
    end

    test "a response with neither text nor tool calls is still nothing to judge" do
      response = Jason.encode!(%{"choices" => [%{"message" => %{"content" => nil}}]})

      refute Evaluations.extract_message_content(response)
    end

    defp judge_prompt_for(request_body) do
      %Evaluation{
        judge_model: "test-model",
        criteria: "Records the call type correctly",
        request_log: %RequestLog{request_body: request_body}
      }
      |> Evaluations.judge_request("[tool_call] record_call_type({\"call_type\":\"Vendor\"})")
      |> Map.fetch!("messages")
      |> List.last()
      |> Map.fetch!("content")
    end

    defp request_with_tools(tool_choice) do
      Jason.encode!(%{
        "messages" => [%{"role" => "user", "content" => "Classify this call"}],
        "tool_choice" => tool_choice,
        "tools" => [
          %{
            "type" => "function",
            "function" => %{"name" => "record_call_type", "description" => "Classify the call"}
          }
        ]
      })
    end

    # Without this the rubric has to say "a tool call is an acceptable
    # answer" in prose, and every rubric that forgets scores a correct call
    # against an empty text body.
    test "the judge is told a tool call is a valid answer when tools were offered" do
      prompt = judge_prompt_for(request_with_tools("auto"))

      assert prompt =~ "ANSWER SHAPE"
      assert prompt =~ "record_call_type"
      assert prompt =~ "[tool_call]"
      assert prompt =~ ~r/not deduct|no penalty/i
    end

    test "a required tool call makes a text-only answer a failure" do
      for choice <- [
            "required",
            "any",
            %{"type" => "function", "function" => %{"name" => "record_call_type"}}
          ] do
        assert judge_prompt_for(request_with_tools(choice)) =~ ~r/required a tool call/i
      end
    end

    test "optional tools leave a plain text answer legitimate" do
      prompt = judge_prompt_for(request_with_tools("auto"))

      assert prompt =~ ~r/optional/i
      refute prompt =~ ~r/required a tool call/i
    end

    test "a request without tools gets no tool guidance at all" do
      body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "What is 2+2?"}]})

      refute judge_prompt_for(body) =~ "ANSWER SHAPE"
    end

    # The seam: extraction feeds the judge prompt, so a tool call that
    # survives extraction but not the prompt is the same silent zero.
    test "the judge prompt carries the tool call and the tools that were offered" do
      evaluation = %Evaluation{
        judge_model: "test-model",
        criteria: "Records the call type correctly",
        request_log: %RequestLog{
          request_body:
            Jason.encode!(%{
              "messages" => [%{"role" => "user", "content" => "Classify this call"}],
              "tool_choice" => "auto",
              "tools" => [
                %{
                  "type" => "function",
                  "function" => %{
                    "name" => "record_call_type",
                    "description" => "Record how to classify the call",
                    "parameters" => %{
                      "type" => "object",
                      "properties" => %{"call_type" => %{"type" => "string"}}
                    }
                  }
                }
              ]
            })
        }
      }

      content = Evaluations.extract_message_content(@tool_call_response)
      request = Evaluations.judge_request(evaluation, content)
      prompt = request["messages"] |> List.last() |> Map.fetch!("content")

      # What the candidate did.
      assert prompt =~ "record_call_type"
      assert prompt =~ "Vendor"

      # What it could have done instead — without the tool definitions the
      # judge cannot tell a correct call from a plausible-looking one.
      assert prompt =~ "Record how to classify the call"
      assert prompt =~ "call_type"
    end
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
    # The extracted assistant message, never the raw provider envelope.
    assert Enum.all?(loaded.runs, &(&1.candidate_output == "Hello from test-model"))
  end

  test "re-running a benchmark scopes summary and rankings to the latest batch" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

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
        name: "Batch scoping",
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

    assert {:ok, _} = Evaluations.run(user, evaluation)
    assert {:ok, _} = Evaluations.run(user, evaluation)

    loaded = Evaluations.get_evaluation!(user, evaluation.id)

    # Full history is retained, but aggregates only cover the latest batch.
    assert length(loaded.runs) == 4
    assert loaded.runs |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 2
    assert Evaluations.summary(loaded).runs == 2
    assert [%{total: 2}] = Evaluations.rankings(loaded)
    assert length(Evaluations.latest_batch_runs(loaded)) == 2
  end

  test "summary sums candidate and judge cost for the latest batch" do
    runs = [
      %EvaluationRun{
        status: "completed",
        score: 80,
        candidate_cost_usd: Decimal.new("0.010"),
        judge_cost_usd: Decimal.new("0.020")
      },
      %EvaluationRun{status: "failed", candidate_cost_usd: Decimal.new("0.005")}
    ]

    summary = Evaluations.summary(%Evaluation{runs: runs})
    assert Decimal.equal?(summary.total_cost_usd, Decimal.new("0.035"))
  end

  test "aggregates price plan-based runs at API list rates with per-run fallback" do
    runs = [
      # Plan-based run: $0 actual, real list prices captured.
      %EvaluationRun{
        status: "completed",
        score: 80,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        candidate_cost_usd: Decimal.new("0"),
        candidate_list_cost_usd: Decimal.new("0.020"),
        judge_cost_usd: Decimal.new("0.010"),
        judge_list_cost_usd: Decimal.new("0.010")
      },
      # Legacy run recorded before list prices existed: falls back to actual.
      %EvaluationRun{
        status: "completed",
        score: 90,
        candidate_provider: "test_provider",
        candidate_model: "test-model",
        candidate_cost_usd: Decimal.new("0.030")
      }
    ]

    evaluation = %Evaluation{runs: runs}

    summary = Evaluations.summary(evaluation)
    assert Decimal.equal?(summary.total_cost_usd, Decimal.new("0.040"))
    assert Decimal.equal?(summary.total_list_cost_usd, Decimal.new("0.060"))

    assert [%{avg_cost: avg_cost}] = Evaluations.rankings(evaluation)
    assert Decimal.equal?(avg_cost, Decimal.new("0.025"))
  end

  test "benchmark runs capture list cost so plan-based candidates stay comparable" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    metered_key = ProvidersFixtures.provider_key_fixture(user)

    plan_key =
      ProvidersFixtures.provider_key_fixture(user, %{provider_slug: "test_provider_coding"})

    # Plan catalog: $0. Metered catalog: the real API list price.
    {:ok, _plan_row} =
      DodoRouter.Models.create_model(%{
        provider_slug: "test_provider_coding",
        model_id: "test-model",
        display_name: "Test Model (plan)",
        input_price_per_million: Decimal.new("0"),
        output_price_per_million: Decimal.new("0")
      })

    {:ok, _metered_row} =
      DodoRouter.Models.create_model(%{
        provider_slug: "test_provider",
        model_id: "test-model",
        display_name: "Test Model",
        input_price_per_million: Decimal.new("1.0"),
        output_price_per_million: Decimal.new("2.0")
      })

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
        name: "Plan cost seam",
        criteria: "Say hello",
        judge_model: "test-model",
        judge_provider_key_id: metered_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => plan_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 1
      })

    assert {:ok, _} = Evaluations.run(user, evaluation)

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert [run] = loaded.runs

    # The plan key made the run free, but the would-cost figure survives.
    assert Decimal.equal?(run.candidate_cost_usd, Decimal.new("0"))
    assert Decimal.compare(run.candidate_list_cost_usd, Decimal.new("0")) == :gt

    # The judge ran on a metered key: list price equals actual price.
    assert Decimal.equal?(run.judge_list_cost_usd, run.judge_cost_usd)
  end

  test "benchmark_running? trusts the registry over a stale running status" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Stale status",
        criteria: "Be correct",
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

    # Simulate a benchmark interrupted by a restart: status stuck on
    # "running" with runs already recorded, but no live benchmark process.
    evaluation
    |> Ecto.Changeset.change(benchmark_status: "running")
    |> DodoRouter.Repo.update!()

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{evaluation_id: evaluation.id, status: "failed"})
    |> DodoRouter.Repo.insert!()

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    refute Evaluations.benchmark_running?(loaded)

    {:ok, _} = Registry.register(DodoRouter.EvaluationRegistry, evaluation.id, nil)
    assert Evaluations.benchmark_running?(loaded)
    assert {:error, :already_running} = Evaluations.enqueue(user, loaded)
  end

  test "a crash mid-run marks the run failed instead of leaving it pending" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Crash guard",
        criteria: "Be correct",
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

    run =
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{evaluation_id: evaluation.id, status: "pending"})
      |> DodoRouter.Repo.insert!()

    assert {:error, %EvaluationRun{status: "failed"}} =
             Evaluations.with_run_failure_guard(run, fn -> raise "boom" end)

    reloaded = DodoRouter.Repo.get!(EvaluationRun, run.id)
    assert reloaded.status == "failed"
    assert reloaded.error =~ "boom"
  end

  test "rejects provider keys the user does not own" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    my_key = ProvidersFixtures.provider_key_fixture(user)
    foreign_key = ProvidersFixtures.provider_key_fixture(other_user)
    log = LogsFixtures.log_fixture(router)

    base = %{
      name: "Ownership",
      criteria: "Be correct",
      judge_model: "test-model",
      judge_provider_key_id: my_key.id,
      candidate_targets: [
        %{
          "provider_key_id" => my_key.id,
          "provider" => "test_provider",
          "model" => "test-model"
        }
      ]
    }

    assert {:error, changeset} =
             Evaluations.create_evaluation(
               user,
               log,
               Map.put(base, :judge_provider_key_id, foreign_key.id)
             )

    assert %{judge_provider_key_id: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Evaluations.create_evaluation(
               user,
               log,
               Map.put(base, :candidate_targets, [
                 %{
                   "provider_key_id" => foreign_key.id,
                   "provider" => "test_provider",
                   "model" => "test-model"
                 }
               ])
             )

    assert %{candidate_targets: [_]} = errors_on(changeset)
  end

  test "rejects malformed candidate targets" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router)

    assert {:error, changeset} =
             Evaluations.create_evaluation(user, log, %{
               name: "Bad targets",
               criteria: "Be correct",
               judge_model: "test-model",
               judge_provider_key_id: provider_key.id,
               candidate_targets: [%{"provider" => "test_provider"}]
             })

    assert %{candidate_targets: [_]} = errors_on(changeset)
  end
end
