defmodule DodoRouter.EvaluationsMessagePatchesTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.Logs.Evaluation
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Replays
  alias DodoRouter.RoutersFixtures

  defp source_body do
    Jason.encode!(%{
      "model" => "m",
      "messages" => [
        %{"role" => "system", "content" => "be helpful"},
        %{"role" => "user", "content" => "run the tests"},
        %{"role" => "tool", "content" => "FAILED 3 of 120 with 40kb of output"},
        %{"role" => "user", "content" => "now what?"}
      ]
    })
  end

  describe "Replays.prepare_request with message_patches" do
    test "replaces only the patched message, before any system-prompt prepend" do
      source = %RequestLog{request_body: source_body()}

      patches = [%{"index" => 2, "content" => "FAILED 3/120 (compressed)"}]

      {:ok, request} =
        Replays.prepare_request(source, "test-model", nil, nil,
          message_patches: patches,
          system_prompt: "be terse"
        )

      assert [
               %{"role" => "system", "content" => "be terse"},
               %{"role" => "user", "content" => "run the tests"},
               %{"role" => "tool", "content" => "FAILED 3/120 (compressed)"},
               %{"role" => "user", "content" => "now what?"}
             ] = request["messages"]
    end

    test "an index with no message behind it is an error, not a skip" do
      source = %RequestLog{request_body: source_body()}
      patches = [%{"index" => 9, "content" => "nope"}]

      assert {:error, :invalid_message_patch} =
               Replays.prepare_request(source, "test-model", nil, nil, message_patches: patches)
    end
  end

  test "patch_messages patches a stored body for the judge and survives junk" do
    patched =
      Replays.patch_messages(source_body(), [%{"index" => 2, "content" => "compressed"}])

    assert %{"messages" => messages} = Jason.decode!(patched)
    assert Enum.at(messages, 2)["content"] == "compressed"
    assert Enum.at(messages, 1)["content"] == "run the tests"

    # Undecodable bodies and empty patch lists pass through unchanged.
    assert Replays.patch_messages("not json", [%{"index" => 0, "content" => "x"}]) == "not json"
    assert Replays.patch_messages(source_body(), []) == source_body()
  end

  test "variant shape validation rejects malformed patches" do
    base = %{
      name: "Test",
      criteria: "Be useful",
      judge_model: "judge-model",
      judge_provider_key_id: Ecto.UUID.generate(),
      request_log_id: Ecto.UUID.generate(),
      evaluated_by_id: Ecto.UUID.generate(),
      candidate_targets: [
        %{"provider_key_id" => Ecto.UUID.generate(), "provider" => "p", "model" => "m"}
      ]
    }

    valid =
      Evaluation.changeset(
        %Evaluation{},
        %{
          base
          | name: "ok"
        }
        |> Map.put(:prompt_variants, [
          %{"name" => "compressed", "message_patches" => [%{"index" => 2, "content" => "x"}]}
        ])
      )

    assert valid.errors[:prompt_variants] == nil

    for bad <- [
          [%{"index" => -1, "content" => "x"}],
          [%{"index" => "2", "content" => "x"}],
          [%{"index" => 2}],
          [%{"index" => 2, "content" => 42}],
          [%{"index" => 2, "content" => "a"}, %{"index" => 2, "content" => "b"}]
        ] do
      changeset =
        Evaluation.changeset(
          %Evaluation{},
          Map.put(base, :prompt_variants, [%{"name" => "bad", "message_patches" => bad}])
        )

      assert {message, _} = changeset.errors[:prompt_variants]
      assert message =~ "message_patches"
    end
  end

  test "a patched variant reaches the candidate and the judge" do
    user = AccountsFixtures.user_fixture()
    {router, _key} = RoutersFixtures.router_fixture(user)
    key = ProvidersFixtures.provider_key_fixture(user)
    log = LogsFixtures.log_fixture(router, %{request_body: source_body()})

    {:ok, evaluation} =
      Evaluations.create_evaluation(user, log, %{
        name: "Compression",
        criteria: "Advance the task",
        judge_model: "judge-model",
        judge_provider_key_id: key.id,
        repetitions: 1,
        prompt_variants: [
          %{"name" => "as-served", "system_prompt" => nil},
          %{
            "name" => "compressed",
            "message_patches" => [%{"index" => 2, "content" => "FAILED 3/120 (compressed)"}]
          }
        ],
        candidate_targets: [
          %{"provider_key_id" => key.id, "provider" => "test_provider", "model" => "test-model"}
        ]
      })

    {:ok, _results} = Evaluations.run(user, evaluation)

    loaded = Evaluations.get_evaluation!(user, evaluation.id)
    runs = Evaluations.latest_batch_runs(loaded)
    assert length(runs) == 2
    assert Enum.all?(runs, &(&1.status == "completed"))

    compressed = Enum.find(runs, &(&1.variant_name == "compressed"))
    as_served = Enum.find(runs, &(&1.variant_name == "as-served"))

    # The candidate call carried the patch...
    candidate_log = Repo.get!(RequestLog, compressed.candidate_log_id)
    assert candidate_log.request_body =~ "FAILED 3/120 (compressed)"
    refute candidate_log.request_body =~ "40kb of output"

    # ...and so did what the judge read; the unpatched variant kept the
    # original bytes.
    judge_log = Repo.get!(RequestLog, compressed.judge_log_id)
    assert judge_log.request_body =~ "compressed"

    baseline_log = Repo.get!(RequestLog, as_served.candidate_log_id)
    assert baseline_log.request_body =~ "40kb of output"
  end
end
