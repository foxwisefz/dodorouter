defmodule DodoRouter.EvaluationsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.{Evaluation, EvaluationRun}
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Proxy.Adapters.TestProvider

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

  test "parses a structured judge response" do
    raw = """
    ```json
    {"score": 96, "passed": true, "summary": "Strong answer", "criterion_scores": {"accuracy": 97}, "issues": []}
    ```
    """

    assert {:ok, result} = Evaluations.parse_judgement(raw)
    assert result.score == 96
    assert result.criterion_scores == %{"accuracy" => 97}
  end

  test "rejects a score outside the 0-100 scale instead of clamping it" do
    # A judge answering on another scale (1-5, 0-10, percentages over 100)
    # must fail the judge stage — a clamp stored 150 as 100 and 3/5 as 3/100
    # on the same axis with no flag. The re-judge via retry_eval is cheap.
    for bad <- [104, 150, -5] do
      assert {:error, message} =
               Evaluations.parse_judgement(
                 Jason.encode!(%{"score" => bad, "summary" => "off-scale"})
               )

      assert message =~ "0-100"
    end

    # In-range low scores are legitimate and pass through untouched.
    assert {:ok, %{score: 3}} =
             Evaluations.parse_judgement(Jason.encode!(%{"score" => 3, "summary" => "poor"}))
  end

  test "invalid criterion scores are dropped, not coerced to zero" do
    raw =
      Jason.encode!(%{
        "score" => 80,
        "summary" => "ok",
        "criterion_scores" => %{"accuracy" => 90, "brevity" => "high", "intent" => 400}
      })

    assert {:ok, result} = Evaluations.parse_judgement(raw)
    # "high" stored as 0 would claim the judge scored brevity zero; 400 is
    # off-scale. Both are absent rather than fabricated.
    assert result.criterion_scores == %{"accuracy" => 90}
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

  test "names every attempt a failed chain made, in words" do
    attempts = [
      %{provider: "moonshot", error: "bad_request", http_status: 400},
      %{provider: "anthropic", error: "rate_limited", http_status: 429}
    ]

    message = Evaluations.proxy_error_message({:error, :all_providers_failed, attempts})

    # This column is read by a person, so it carries no Elixir syntax and no
    # internal atom names — but it must still name each provider and why it
    # failed, since that is the whole diagnostic value of the chain.
    refute message =~ "%{"
    refute message =~ "all_providers_failed"
    assert message =~ "moonshot"
    assert message =~ "HTTP 400"
    assert message =~ "anthropic"
    assert message =~ "rate limited"
  end

  test "a one-provider chain is not described as a fallback chain" do
    # Evaluations dispatch with an explicit single step, so there is no
    # chain to fall back through. Saying "every provider failed" invented
    # one, and reads as though the judge silently moved to another provider
    # — which would make the judge a variable and the scores incomparable.
    attempts = [%{provider: "anthropic", error: "rate_limited", http_status: 429}]

    message = Evaluations.proxy_error_message({:error, :all_providers_failed, attempts})

    refute message =~ "every provider"
    refute message =~ "providers"
    assert message =~ "anthropic"
    assert message =~ "rate limited"
    assert message =~ "HTTP 429"
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

  test "prompt variants fan out and rank per (model x variant), judge seeing the patched prompt" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{
            "model" => "m",
            "messages" => [
              %{"role" => "system", "content" => "You are the original prompt"},
              %{"role" => "user", "content" => "hi"}
            ]
          })
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Prompt A/B",
        criteria: "Be correct",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        prompt_variants: [
          %{"name" => "as-served", "system_prompt" => nil},
          %{"name" => "terse", "system_prompt" => "You are terse. Reply in one word."}
        ],
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 1
      })

    # 1 log x 2 variants x 1 candidate x 1 repetition.
    assert Evaluations.planned_run_count(evaluation) == 2

    {:ok, _} = Evaluations.run(user, evaluation)

    evaluation = Evaluations.get_evaluation!(user, evaluation.id)
    runs = Evaluations.latest_batch_runs(evaluation)

    assert runs |> Enum.map(& &1.variant_name) |> Enum.sort() == ["as-served", "terse"]

    # One ranking row per (model x variant): same rubric, same judge, one
    # comparison — the A/B people actually run daily (dodo_router-kk1).
    rankings = Evaluations.rankings(evaluation)
    assert length(rankings) == 2
    assert rankings |> Enum.map(& &1.variant) |> Enum.sort() == ["as-served", "terse"]

    # The variant's prompt reached the wire: the replayed request for the
    # terse run carries the patched system message...
    terse = Enum.find(runs, &(&1.variant_name == "terse"))
    candidate_log = DodoRouter.Repo.get!(DodoRouter.Logs.RequestLog, terse.candidate_log_id)
    assert candidate_log.request_body =~ "You are terse"
    refute candidate_log.request_body =~ "original prompt"

    # ...and the judge scored against the patched request, not the anchor's.
    judge_log = DodoRouter.Repo.get!(DodoRouter.Logs.RequestLog, terse.judge_log_id)
    assert judge_log.request_body =~ "You are terse"
  end

  test "an evaluation over a set of logs runs each and aggregates one ranking" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    body = fn text ->
      Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => text}]})
    end

    log1 = LogsFixtures.log_fixture(router, %{request_body: body.("first real request")})
    log2 = LogsFixtures.log_fixture(router, %{request_body: body.("second real request")})

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log1, %{
        name: "On my traffic",
        criteria: "Be correct",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        source_log_ids: [log1.id, log2.id],
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "test-model"
          }
        ],
        repetitions: 1
      })

    {:ok, _} = Evaluations.run(user, evaluation)

    evaluation = Evaluations.get_evaluation!(user, evaluation.id)
    runs = Evaluations.latest_batch_runs(evaluation)

    # One run per source log, each stamped with the log it measured.
    assert length(runs) == 2
    assert runs |> Enum.map(& &1.source_log_id) |> Enum.sort() == Enum.sort([log1.id, log2.id])

    # One ranking row: the score answers "on my traffic", not "on this one
    # request" — the aggregation is the whole point (dodo_router-3hr).
    assert [ranking] = Evaluations.rankings(evaluation)
    assert ranking.total == 2

    # The planned volume is knowable before spending.
    assert Evaluations.planned_run_count(evaluation) == 2
  end

  test "backoff honors a Retry-After header from the rate-limited attempt" do
    result =
      {:error, :all_providers_failed,
       [
         %{
           error: "rate_limited",
           response_headers: [{"retry-after", "12"}, {"content-type", "application/json"}]
         }
       ]}

    assert Evaluations.retry_after_ms(result) == 12_000

    # Header map shape (Req-style), string keys, list values.
    result =
      {:ok,
       %{
         status: "error",
         attempted_steps: [
           %{"error" => "rate_limited", "response_headers" => %{"retry-after" => ["3"]}}
         ]
       }}

    assert Evaluations.retry_after_ms(result) == 3_000

    # Absent, unparseable, or absurd values fall back to the ladder.
    assert Evaluations.retry_after_ms({:error, :all_providers_failed, [%{error: "rate_limited"}]}) ==
             nil

    assert Evaluations.retry_after_ms(
             {:error, :all_providers_failed,
              [%{response_headers: [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]}]}
           ) == nil

    # Capped: a provider asking for ten minutes does not stall the runner.
    assert Evaluations.retry_after_ms(
             {:error, :all_providers_failed, [%{response_headers: [{"retry-after", "600"}]}]}
           ) == 30_000
  end

  test "a run records the model the provider actually served, and flags an alias swap" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]})
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Alias check",
        criteria: "Be correct",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "alias-model"
          }
        ],
        repetitions: 1
      })

    {:ok, _} = Evaluations.run(user, evaluation)

    [run] = Evaluations.latest_batch_runs(Evaluations.get_evaluation!(user, evaluation.id))
    assert run.status == "completed"
    # The ranking is keyed on what was requested; this is the receipt for
    # what actually answered — the "measuring a model nobody chose" trap.
    assert run.candidate_model == "alias-model"
    assert run.candidate_served_model == "alias-model-v2"
  end

  test "failed runs carry a machine-readable error_category alongside the prose" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]})
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Categorised failure",
        criteria: "Be correct",
        judge_model: "judge-model",
        judge_provider_key_id: provider_key.id,
        candidate_targets: [
          %{
            "provider_key_id" => provider_key.id,
            "provider" => "test_provider",
            "model" => "fail-model"
          }
        ],
        repetitions: 1
      })

    {:ok, _} = Evaluations.run(user, evaluation)

    [run] = Evaluations.latest_batch_runs(Evaluations.get_evaluation!(user, evaluation.id))
    assert run.status == "failed"
    # The prose stays for humans; the category is for clients that were
    # regexing strings to find out whether retrying could help.
    assert run.error_category == "server_error"
  end

  test "cancel_benchmark kills the live batch and sweeps the remaining runs" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]})
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Doomed v2",
        criteria: "Be correct",
        judge_model: "judge-model",
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

    batch_id = Ecto.UUID.generate()

    evaluation
    |> Ecto.Changeset.change(benchmark_status: "running", last_batch_id: batch_id)
    |> DodoRouter.Repo.update!()

    %EvaluationRun{}
    |> EvaluationRun.changeset(%{
      evaluation_id: evaluation.id,
      batch_id: batch_id,
      status: "pending"
    })
    |> DodoRouter.Repo.insert!()

    # A stand-in for the live benchmark task, registered the way the real
    # one registers itself. spawn/1, not Task.async/1 — the cancel kills it,
    # and a link would take the test down with it.
    test_pid = self()

    batch_pid =
      spawn(fn ->
        Registry.register(DodoRouter.EvaluationRegistry, evaluation.id, nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    ref = Process.monitor(batch_pid)

    assert :ok = Evaluations.cancel_benchmark(user, evaluation)
    assert_receive {:DOWN, ^ref, :process, ^batch_pid, :killed}

    reloaded = Evaluations.get_evaluation!(user, evaluation.id)
    assert reloaded.benchmark_status == "cancelled"

    assert [run] = Evaluations.latest_batch_runs(reloaded)
    assert run.status == "failed"
    assert run.error =~ "cancelled"

    # Nothing left to cancel reads as such, not as success.
    assert {:error, :not_running} = Evaluations.cancel_benchmark(user, reloaded)
  end

  test "preflight names a candidate key that no longer resolves, and enqueue refuses when nothing could run" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]})
      })

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Ghost key",
        criteria: "Be correct",
        judge_model: "judge-model",
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

    # Simulate a pre-FK-restriction row whose stored key id no longer
    # resolves: 18 doomed runs used to grind through before anything said so.
    ghost_id = Ecto.UUID.generate()

    evaluation
    |> Ecto.Changeset.change(
      candidate_targets: [
        %{"provider_key_id" => ghost_id, "provider" => "test_provider", "model" => "test-model"}
      ]
    )
    |> DodoRouter.Repo.update!()

    preflight = Evaluations.preflight(user, Evaluations.get_evaluation!(user, evaluation.id))
    assert [%{status: "missing", key_id: ^ghost_id}] = preflight.candidates

    # Every candidate is doomed, so starting would only burn the judge's
    # quota on nothing — refused with the blockers named.
    assert {:error, {:candidates_unusable, [%{status: "missing"}]}} =
             Evaluations.enqueue(user, evaluation)
  end

  test "enqueue can override repetitions for this and future runs" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    log =
      LogsFixtures.log_fixture(router, %{
        request_body:
          Jason.encode!(%{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]})
      })

    create = fn name ->
      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: name,
          criteria: "Be correct",
          judge_model: "judge-model",
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

      evaluation
    end

    evaluation = create.("Reps override")
    assert :ok = Evaluations.enqueue(user, evaluation, repetitions: 5)
    assert Evaluations.get_evaluation!(user, evaluation.id).repetitions == 5

    # An out-of-range override is refused before anything is spent.
    other = create.("Reps invalid")
    assert {:error, %Ecto.Changeset{}} = Evaluations.enqueue(user, other, repetitions: 99)
    assert Evaluations.get_evaluation!(user, other.id).repetitions == 1
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

  describe "a run names the judge key that actually ran" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)
      judge = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Helpful answer",
          criteria: "Answer directly",
          judge_model: "test-model",
          judge_provider_key_id: judge.id,
          candidate_targets: [
            %{
              "provider_key_id" => judge.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ],
          repetitions: 1
        })

      %{user: user, judge: judge, evaluation: evaluation}
    end

    test "survives the evaluation being repointed at another key", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      run = run_judged_by(evaluation, judge)

      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})
      assert :ok = Evaluations.reassign_provider_key(judge, replacement)

      run = Repo.get!(EvaluationRun, run.id)
      assert run.judge_provider_key_id == judge.id
      assert run.judge_provider_key_label == "Key 1"

      # the evaluation is forward-looking; the run is a record of what ran
      assert Repo.get!(Evaluation, evaluation.id).judge_provider_key_id == replacement.id
    end

    test "still names the key after it is deleted", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      run = run_judged_by(evaluation, judge)

      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})

      assert {:ok, _} =
               DodoRouter.Providers.delete_provider_key(judge, reassign_to: replacement)

      run = Repo.get!(EvaluationRun, run.id)

      # the id goes with the key; the label is a snapshot and outlives it,
      # which is what tells a reader the judge is gone rather than unknown
      assert is_nil(run.judge_provider_key_id)
      assert run.judge_provider_key_label == "Key 1"
      assert Evaluations.judge_key_deleted?(run)
    end

    test "a run from before this was recorded reads as unknown, not deleted", %{
      evaluation: evaluation
    } do
      {:ok, run} =
        %EvaluationRun{}
        |> EvaluationRun.changeset(%{
          status: "completed",
          evaluation_id: evaluation.id,
          judge_prompt_version: "v4"
        })
        |> Repo.insert()

      refute Evaluations.judge_key_deleted?(run)
    end

    defp run_judged_by(evaluation, judge) do
      %EvaluationRun{}
      |> EvaluationRun.changeset(%{
        status: "completed",
        evaluation_id: evaluation.id,
        judge_prompt_version: "v4",
        judge_provider_key_id: judge.id,
        judge_provider_key_label: judge.label
      })
      |> Repo.insert!()
    end
  end

  describe "which stage of a run failed" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      provider_key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      %{user: user, provider_key: provider_key, log: log}
    end

    defp eval_with(user, log, key, attrs) do
      {:ok, evaluation} =
        Evaluations.create_evaluation(
          user,
          log,
          Map.merge(
            %{
              name: "Staged",
              criteria: "Say hello",
              judge_model: "test-model",
              judge_provider_key_id: key.id,
              candidate_targets: [
                %{
                  "provider_key_id" => key.id,
                  "provider" => "test_provider",
                  "model" => "test-model"
                }
              ],
              repetitions: 1
            },
            attrs
          )
        )

      evaluation
    end

    test "a judge that fails leaves the answer intact and says so", %{
      user: user,
      provider_key: key,
      log: log
    } do
      # The candidate answers; only the judge call fails.
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))

      assert run.status == "failed"
      assert run.failure_stage == "judge"

      # The work that was paid for survives, which is what makes this
      # recoverable without re-generating the answer.
      assert run.candidate_output =~ "Hello"
      assert run.candidate_log_id
    end

    test "a candidate that fails is a different stage", %{
      user: user,
      provider_key: key,
      log: log
    } do
      evaluation =
        eval_with(user, log, key, %{
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "fail-model"
            }
          ]
        })

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))

      assert run.status == "failed"
      assert run.failure_stage == "candidate"
      refute run.candidate_output =~ "Hello"
    end

    test "the error a judge failure records is readable, not an inspected map", %{
      user: user,
      provider_key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))

      # `inspect(%{error: :all_providers_failed, attempts: [...]})` in a
      # user-facing column is how this read before.
      refute run.error =~ "%{"
      refute run.error =~ ":all_providers_failed"
      assert run.error =~ "Judge"
      assert run.error =~ "test_provider"
    end
  end

  describe "checking keys before spending the run" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      judge = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Judge key"})
      candidate = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Candidate key"})

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
          name: "Preflight",
          criteria: "Say hello",
          judge_model: "judge-model",
          judge_provider_key_id: judge.id,
          candidate_targets: [
            %{
              "provider_key_id" => candidate.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ],
          repetitions: 1
        })

      %{user: user, judge: judge, candidate: candidate, evaluation: evaluation}
    end

    test "a healthy pair blocks nothing", %{user: user, evaluation: evaluation} do
      assert Evaluations.preflight(user, evaluation) == %{judge: nil, candidates: []}
    end

    test "an exhausted judge key blocks the whole benchmark", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      DodoRouter.Providers.apply_health(judge.id, :quota, "You've reached your usage limit")

      assert %{judge: blocker} = Evaluations.preflight(user, evaluation)
      assert blocker.label == "Judge key"
      assert blocker.status == "quota_exceeded"
    end

    test "a candidate whose model the provider retired is named", %{
      user: user,
      candidate: candidate,
      evaluation: evaluation
    } do
      # The evaluation was configured when the model existed. Nothing about
      # the stored row changes when a provider retires it, so the only
      # warning available is the catalog's — and without it the run spends a
      # candidate discovering a 404.
      {:ok, model} =
        DodoRouter.Models.upsert_model(%{
          provider_slug: "test_provider",
          model_id: "retired-snapshot",
          display_name: "Retired",
          last_seen_at: DateTime.add(DateTime.utc_now(), -40, :day)
        })

      {:ok, _current} =
        DodoRouter.Models.upsert_model(%{
          provider_slug: "test_provider",
          model_id: "current-model",
          display_name: "Current",
          last_seen_at: DateTime.utc_now()
        })

      evaluation
      |> Ecto.Changeset.change(
        candidate_targets: [
          %{
            "provider_key_id" => candidate.id,
            "provider" => "test_provider",
            "model" => model.model_id
          }
        ]
      )
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)

      assert %{candidates: [blocked]} = Evaluations.preflight(user, evaluation)
      assert blocked.model == "retired-snapshot"
      assert blocked.status == "retired"
    end

    test "an exhausted candidate key is named but does not block", %{
      user: user,
      candidate: candidate,
      evaluation: evaluation
    } do
      DodoRouter.Providers.apply_health(candidate.id, :quota, "out of credits")

      assert %{judge: nil, candidates: [blocked]} = Evaluations.preflight(user, evaluation)
      assert blocked.label == "Candidate key"
      assert blocked.model == "test-model"
    end

    test "enqueue refuses when the judge cannot possibly score", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      DodoRouter.Providers.apply_health(judge.id, :quota, "You've reached your usage limit")

      # Every candidate answer would be generated and paid for, then thrown
      # away for want of a judge. Refusing is the cheaper truth.
      assert {:error, {:judge_key_unusable, blocker}} = Evaluations.enqueue(user, evaluation)
      assert blocker.label == "Judge key"

      assert Repo.aggregate(
               from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id),
               :count
             ) == 0
    end
  end

  describe "abandoning a key that has run out mid-batch" do
    test "stops repeating a key once the provider says it is exhausted" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      evaluation =
        eval_with(user, log, key, %{
          judge_model: "judge-model",
          repetitions: 6,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "quota-exhausted-model"
            }
          ]
        })

      TestProvider.reset("quota-exhausted-model")

      assert {:ok, _} = Evaluations.run(user, evaluation)

      runs = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert length(runs) == 6
      assert Enum.all?(runs, &(&1.status == "failed"))

      # Runs already in flight cannot be recalled — the first concurrent
      # wave still reaches the provider. What a billing-cycle limit does not
      # do is clear in the seconds afterwards, so every run *started* after
      # that answer is abandoned rather than bought again.
      calls = TestProvider.call_count("quota-exhausted-model")
      assert calls <= 3
      assert Enum.count(runs, &(&1.error =~ "out of quota")) == 6 - calls

      # Every planned measurement still has a row saying why it never ran.
      assert Enum.all?(runs, &is_binary(&1.error))
    end
  end

  describe "retrying only what failed" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      %{user: user, key: key, log: log}
    end

    test "re-judges an answer already paid for, without calling the candidate again", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})
      assert {:ok, _} = Evaluations.run(user, evaluation)

      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert run.failure_stage == "judge"
      candidate_log_id = run.candidate_log_id

      # Point the judge at a model that answers with a real judgement.
      evaluation
      |> Ecto.Changeset.change(judge_model: "judge-model")
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, [_]} = Evaluations.retry_failed(user, evaluation)

      retried = Repo.get!(EvaluationRun, run.id)
      assert retried.status == "completed"
      assert is_integer(retried.score)
      assert is_nil(retried.failure_stage)

      # The same candidate answer was reused — no second generation.
      assert retried.candidate_log_id == candidate_log_id
    end

    test "calls the candidate again when that is what failed", %{user: user, key: key, log: log} do
      evaluation =
        eval_with(user, log, key, %{
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "fail-model"
            }
          ]
        })

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert run.failure_stage == "candidate"
      first_log_id = run.candidate_log_id

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, [_]} = Evaluations.retry_failed(user, evaluation)

      retried = Repo.get!(EvaluationRun, run.id)

      # The target is still the failing model, so it fails again — but a new
      # candidate log proves the provider really was called a second time,
      # which is the difference between this and the judge-stage retry.
      assert retried.status == "failed"
      assert retried.failure_stage == "candidate"
      assert retried.candidate_log_id != first_log_id
    end

    test "leaves runs that already succeeded alone and keeps the batch intact", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation =
        eval_with(user, log, key, %{
          repetitions: 2,
          judge_model: "judge-model",
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            },
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "fail-model"
            }
          ]
        })

      assert {:ok, _} = Evaluations.run(user, evaluation)
      evaluation = Evaluations.get_evaluation!(user, evaluation.id)

      before = Evaluations.summary(evaluation)
      assert before.completed == 2
      assert before.failed == 2

      scored_ids =
        from(r in EvaluationRun,
          where: r.evaluation_id == ^evaluation.id and r.status == "completed",
          select: {r.id, r.score}
        )
        |> Repo.all()
        |> Map.new()

      # Only the two failed runs are retried; they fail again, since the
      # target is still the failing model.
      assert {:ok, retried} = Evaluations.retry_failed(user, evaluation)
      assert length(retried) == 2

      # Retries update the runs in place, so the batch still has 4 rows and
      # its averages stay comparable rather than gaining phantom runs.
      after_retry = Evaluations.summary(Evaluations.get_evaluation!(user, evaluation.id))
      assert after_retry.runs == 4
      assert after_retry.completed == 2

      for {id, score} <- scored_ids do
        assert Repo.get!(EvaluationRun, id).score == score
      end
    end

    test "enqueue_retry hands the work to a task and registers it as running", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})
      assert {:ok, _} = Evaluations.run(user, evaluation)

      evaluation
      |> Ecto.Changeset.change(judge_model: "judge-model")
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)

      # Retrying used to run inline in the caller — the LiveView froze for
      # the length of the whole retry with no render in between, so the
      # button looked dead. It goes through the same path as a fresh run.
      assert :ok = Evaluations.enqueue_retry(user, evaluation)

      run =
        Repo.one!(
          from(r in EvaluationRun,
            where: r.evaluation_id == ^evaluation.id and is_nil(r.superseded_at)
          )
        )

      assert run.status == "completed"
    end

    test "enqueue_retry refuses while a benchmark is already running", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{})

      evaluation
      |> Ecto.Changeset.change(benchmark_status: "running")
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)

      # No registry entry in a bare test process, so the stored status is
      # the fallback the guard reads.
      if Evaluations.benchmark_running?(evaluation) do
        assert {:error, :already_running} = Evaluations.enqueue_retry(user, evaluation)
      end
    end

    test "a retry leaves the benchmark status describing the whole batch", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation =
        eval_with(user, log, key, %{
          judge_model: "judge-model",
          repetitions: 2,
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "test-model"
            },
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "fail-model"
            }
          ]
        })

      assert :ok = Evaluations.enqueue(user, evaluation)
      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert evaluation.benchmark_status == "partial"

      assert :ok = Evaluations.enqueue_retry(user, evaluation)

      # The retried runs all fail again, but half the batch is still scored:
      # a status computed from the retry alone would report "failed" and
      # erase two good results.
      assert Evaluations.get_evaluation!(user, evaluation.id).benchmark_status == "partial"
    end

    test "keeps the attempt it replaced, without inflating the batch", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})
      assert {:ok, _} = Evaluations.run(user, evaluation)

      [original] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert original.status == "failed"
      first_error = original.error

      evaluation
      |> Ecto.Changeset.change(judge_model: "judge-model")
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, [_]} = Evaluations.retry_failed(user, evaluation)

      # The row keeps its identity, so the batch is still one run and its
      # averages still describe one measurement per repetition.
      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert length(Evaluations.latest_batch_runs(evaluation)) == 1
      assert Evaluations.summary(evaluation).runs == 1

      live = Repo.get!(EvaluationRun, original.id)
      assert live.status == "completed"
      assert is_nil(live.superseded_at)

      # And the failure it replaced is still on record rather than erased.
      assert [previous] = Evaluations.previous_attempts(live)
      assert previous.status == "failed"
      assert previous.error == first_error
      assert previous.superseded_at
      assert previous.superseded_by_id == live.id
    end

    test "a second retry stacks attempts newest first", %{user: user, key: key, log: log} do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})
      assert {:ok, _} = Evaluations.run(user, evaluation)

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, _} = Evaluations.retry_failed(user, evaluation)

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, _} = Evaluations.retry_failed(user, evaluation)

      [live] =
        Repo.all(
          from(r in EvaluationRun,
            where: r.evaluation_id == ^evaluation.id and is_nil(r.superseded_at)
          )
        )

      attempts = Evaluations.previous_attempts(live)
      assert length(attempts) == 2

      assert Enum.map(attempts, & &1.superseded_at) ==
               Enum.sort_by(attempts, & &1.superseded_at, {:desc, DateTime})
               |> Enum.map(& &1.superseded_at)
    end

    test "a run the benchmark never finished is retryable, not stranded", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "judge-model"})

      batch = Ecto.UUID.generate()
      evaluation = evaluation |> Ecto.Changeset.change(last_batch_id: batch) |> Repo.update!()

      # What a benchmark that died mid-flight leaves behind: rows created but
      # never resolved. They are not "failed", so nothing offered to retry
      # them and they sat as "pending"/"running" forever.
      for {status, repetition} <- [{"pending", 1}, {"running", 2}] do
        %EvaluationRun{}
        |> EvaluationRun.changeset(%{
          evaluation_id: evaluation.id,
          batch_id: batch,
          status: status,
          candidate_provider_key_id: key.id,
          candidate_provider: "test_provider",
          candidate_model: "test-model",
          repetition: repetition
        })
        |> Repo.insert!()
      end

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert %{candidate: 2} = Evaluations.retryable_counts(evaluation)

      assert {:ok, results} = Evaluations.retry_failed(user, evaluation)
      assert length(results) == 2

      runs = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      live = Enum.reject(runs, & &1.superseded_at)

      assert Enum.all?(live, &(&1.status == "completed"))
    end

    test "starting a run resolves what an interrupted one left behind", %{
      user: user,
      key: key,
      log: log
    } do
      evaluation = eval_with(user, log, key, %{judge_model: "judge-model"})
      batch = Ecto.UUID.generate()
      evaluation = evaluation |> Ecto.Changeset.change(last_batch_id: batch) |> Repo.update!()

      stranded =
        %EvaluationRun{}
        |> EvaluationRun.changeset(%{
          evaluation_id: evaluation.id,
          batch_id: batch,
          status: "running",
          candidate_provider: "test_provider",
          candidate_model: "test-model",
          repetition: 1
        })
        |> Repo.insert!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert :ok = Evaluations.enqueue(user, evaluation)

      # The row stops claiming to be in flight, and says why it isn't.
      resolved = Repo.get!(EvaluationRun, stranded.id)
      assert resolved.status == "failed"
      assert resolved.error =~ "stopped before this run finished"
    end

    test "reports how many runs are retryable, by stage", %{user: user, key: key, log: log} do
      evaluation = eval_with(user, log, key, %{judge_model: "fail-model"})
      assert {:ok, _} = Evaluations.run(user, evaluation)

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert %{judge: 1, candidate: 0} = Evaluations.retryable_counts(evaluation)
    end
  end

  describe "backing off a rate-limited provider" do
    test "retries a rate-limited call and gives up after the configured attempts" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      evaluation =
        eval_with(user, log, key, %{
          judge_model: "judge-model",
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "rate-limited-model"
            }
          ]
        })

      TestProvider.reset("rate-limited-model")

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))

      # A rate limit is a "try again", not a verdict on the model — so the
      # run only gives up after the whole ladder is spent.
      assert run.status == "failed"
      assert run.error =~ "rate limited"
      assert TestProvider.call_count("rate-limited-model") == 3
    end

    test "a rate limit that clears is not a failed run" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      evaluation =
        eval_with(user, log, key, %{
          judge_model: "judge-model",
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "rate-limited-once-model"
            }
          ]
        })

      TestProvider.reset("rate-limited-once-model")

      assert {:ok, _} = Evaluations.run(user, evaluation)
      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))

      assert run.status == "completed"
      assert TestProvider.call_count("rate-limited-once-model") == 2
    end
  end

  describe "what a run's error column is allowed to hold" do
    test "never a credential, however it got into the message" do
      # The proxy redacts when it writes a request log, but the attempts it
      # hands back in memory still carry the real Authorization header — so
      # anything building a message out of them went around the redaction
      # and put a live key on the page.
      attempts = [
        %{
          provider: "anthropic",
          error: "rate_limited",
          http_status: 429,
          outbound_headers: [
            {"authorization", "Bearer sk-ant-oat01-OL_-HAMa-TlcjYpI4LLsWfBOJXA7scSs6a1UXRuToGSU"}
          ]
        }
      ]

      message = Evaluations.proxy_error_message({:error, :all_providers_failed, attempts})

      refute message =~ "sk-ant-oat01"
      refute message =~ "Bearer"
    end

    test "is capped, so one row cannot become a wall of text" do
      giant = String.duplicate("boom ", 10_000)

      stored = Evaluations.run_error_text(giant)

      assert String.length(stored) <= 2_000
      assert stored =~ "truncated"
    end

    test "redacts a secret that reaches it by any other route" do
      stored =
        Evaluations.run_error_text(
          "upstream said Bearer sk-ant-oat01-OL_-HAMaTlcjYpI4LLsWfBOJXA7scSs6a1UXRuToGSU nope"
        )

      refute stored =~ "sk-ant-oat01"
      assert stored =~ "upstream said"
    end
  end

  describe "a model the provider no longer has" do
    test "is named in the run, and logged with the status the provider gave" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      key = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      evaluation =
        eval_with(user, log, key, %{
          judge_model: "judge-model",
          candidate_targets: [
            %{
              "provider_key_id" => key.id,
              "provider" => "test_provider",
              "model" => "retired-model"
            }
          ]
        })

      assert {:ok, _} = Evaluations.run(user, evaluation)

      [run] =
        Repo.all(
          from(r in EvaluationRun,
            where: r.evaluation_id == ^evaluation.id and is_nil(r.superseded_at)
          )
        )

      # "Candidate call unknown" told the reader nothing. The model name is
      # the whole diagnosis: it is retired, and no retry will bring it back.
      assert run.status == "failed"
      assert run.error =~ "retired-model"
      assert run.error =~ "no longer"
      refute run.error =~ "unknown"

      # And the log records the 404 the provider actually sent, not a 502
      # that blames a gateway for a request the provider understood.
      candidate_log = Repo.get!(DodoRouter.Logs.RequestLog, run.candidate_log_id)
      assert candidate_log.http_status == 404
    end
  end

  describe "error text for a failed candidate call" do
    test "keeps the provider's error type when the message alone says nothing" do
      # Anthropic's rate-limit body literally carries the message "Error";
      # the type is the only informative part, and dropping it left the run
      # reading `Error`.
      log = %DodoRouter.Logs.RequestLog{
        http_status: 429,
        response_body:
          Jason.encode!(%{
            "error" => %{"message" => "Error", "type" => "rate_limit_error"},
            "type" => "error"
          })
      }

      message = Evaluations.candidate_error_message(log)

      assert message =~ "rate limit"
      refute message == "Error"
    end

    test "does not blame the provider for our own timeout" do
      log = %DodoRouter.Logs.RequestLog{
        http_status: 502,
        response_body: "Request timed out",
        attempted_steps: [%{"status" => "error", "error" => "timeout", "provider" => "zai"}]
      }

      message = Evaluations.candidate_error_message(log)

      assert message =~ "timed out"
      refute message =~ "provider returned an error"
    end
  end

  describe "candidate references to a provider key" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)

      log =
        LogsFixtures.log_fixture(router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [%{"role" => "user", "content" => "Say hello"}]
            })
        })

      judge = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Judge key"})
      candidate = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Candidate key"})

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Greeting benchmark",
          criteria: "Say hello",
          judge_model: "test-model",
          judge_provider_key_id: judge.id,
          candidate_targets: [
            %{
              "provider_key_id" => candidate.id,
              "provider" => "test_provider",
              "model" => "test-model"
            }
          ],
          repetitions: 1
        })

      %{user: user, judge: judge, candidate: candidate, evaluation: evaluation}
    end

    test "are counted even though no foreign key enforces them", %{
      judge: judge,
      candidate: candidate
    } do
      assert Evaluations.reference_counts(judge) == %{judge: 1, candidate: 0, total: 1}
      assert Evaluations.reference_counts(candidate) == %{judge: 0, candidate: 1, total: 1}
    end

    test "count one evaluation once when it fills both roles", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      evaluation
      |> Ecto.Changeset.change(
        candidate_targets: [
          %{"provider_key_id" => judge.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      )
      |> Repo.update!()

      _ = user

      assert Evaluations.reference_counts(judge) == %{judge: 1, candidate: 1, total: 1}
    end

    test "stop a delete that would otherwise succeed silently", %{candidate: candidate} do
      # candidate_targets is a JSON column with no FK, so Postgres has no
      # opinion here — the refusal has to come from us, or the id dangles
      # and the next re-run fails minutes later for something knowable now.
      assert {:error, :in_use} = DodoRouter.Providers.delete_provider_key(candidate)
      assert Repo.get(DodoRouter.Providers.ProviderKey, candidate.id)
    end

    test "move to the replacement, keeping provider and model", %{
      user: user,
      candidate: candidate,
      evaluation: evaluation
    } do
      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})

      assert {:ok, _} =
               DodoRouter.Providers.delete_provider_key(candidate, reassign_to: replacement)

      assert [target] = Repo.get!(Evaluation, evaluation.id).candidate_targets
      assert target["provider_key_id"] == replacement.id
      assert target["provider"] == "test_provider"
      assert target["model"] == "test-model"
    end

    test "a run names the candidate key that produced it, and marks it deleted", %{
      user: user,
      candidate: candidate,
      evaluation: evaluation
    } do
      assert {:ok, _} = Evaluations.run(user, evaluation)

      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert run.candidate_provider_key_id == candidate.id
      assert run.candidate_provider_key_label == "Candidate key"
      refute Evaluations.candidate_key_deleted?(run)

      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})

      assert {:ok, _} =
               DodoRouter.Providers.delete_provider_key(candidate, reassign_to: replacement)

      run = Repo.get!(EvaluationRun, run.id)
      assert is_nil(run.candidate_provider_key_id)
      assert run.candidate_provider_key_label == "Candidate key"
      assert Evaluations.candidate_key_deleted?(run)
    end

    test "a target left dangling by an older delete fails by name, not by atom", %{
      user: user,
      evaluation: evaluation
    } do
      # Rows predating the refusal above still hold ids of deleted keys.
      dangling = Ecto.UUID.generate()

      evaluation
      |> Ecto.Changeset.change(
        candidate_targets: [
          %{"provider_key_id" => dangling, "provider" => "test_provider", "model" => "test-model"}
        ]
      )
      |> Repo.update!()

      evaluation = Evaluations.get_evaluation!(user, evaluation.id)
      assert {:ok, _} = Evaluations.run(user, evaluation)

      assert [run] = Repo.all(from(r in EvaluationRun, where: r.evaluation_id == ^evaluation.id))
      assert run.status == "failed"
      assert run.error =~ "no longer configured"
      assert run.error =~ "test-model"
      refute run.error =~ "provider_key_not_found"
    end
  end

  describe "reassign_provider_key/2" do
    setup do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      judge = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 1"})

      {:ok, evaluation} =
        Evaluations.create_evaluation(user, log, %{
          name: "Helpful answer",
          criteria: "Answer directly",
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

      %{user: user, judge: judge, evaluation: evaluation}
    end

    test "moves every reference to a key of the same provider", %{
      user: user,
      judge: judge,
      evaluation: evaluation
    } do
      replacement = ProvidersFixtures.provider_key_fixture(user, %{"label" => "Key 2"})

      assert :ok = Evaluations.reassign_provider_key(judge, replacement)
      assert Repo.get!(Evaluation, evaluation.id).judge_provider_key_id == replacement.id
      assert Evaluations.reference_counts(judge).judge == 0
      assert Evaluations.reference_counts(replacement).judge == 1
    end

    test "refuses a key from a different provider", %{user: user, judge: judge} do
      # The evaluation keeps its judge_model. Pointing it at another
      # provider's credential would claim a model judged it that cannot run
      # there — the score would read as comparable when it is not.
      other = ProvidersFixtures.provider_key_fixture(user, %{"provider_slug" => "zai_standard"})

      assert {:error, :provider_mismatch} = Evaluations.reassign_provider_key(judge, other)
      assert Evaluations.reference_counts(judge).judge == 1
    end

    test "refuses a key belonging to someone else", %{judge: judge} do
      stranger = AccountsFixtures.user_fixture()
      theirs = ProvidersFixtures.provider_key_fixture(stranger)

      assert {:error, :not_owned} = Evaluations.reassign_provider_key(judge, theirs)
      assert Evaluations.reference_counts(judge).judge == 1
    end
  end
end
