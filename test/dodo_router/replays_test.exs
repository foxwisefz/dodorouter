defmodule DodoRouter.ReplaysTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Replays
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.RoutersFixtures

  setup do
    user = AccountsFixtures.user_fixture()
    {router, _api_key} = RoutersFixtures.router_fixture(user)
    provider_key = ProvidersFixtures.provider_key_fixture(user)

    source =
      LogsFixtures.log_fixture(router, %{
        final_model: "original-model",
        latency_ms: 1000,
        request_body:
          Jason.encode!(%{
            "model" => "original-model",
            "stream" => true,
            "stream_options" => %{"include_usage" => true},
            "user" => "end-user-123",
            "temperature" => 0.7,
            "messages" => [%{"role" => "user", "content" => "hi"}]
          }),
        response_body: Jason.encode!(%{"choices" => []})
      })

    %{user: user, router: router, provider_key: provider_key, source: source}
  end

  defp target(ctx, model \\ "test-model") do
    %{provider_key_id: ctx.provider_key.id, model: model}
  end

  describe "replay/3" do
    test "replays through the target and links the new log to the original", ctx do
      assert {:ok, %RequestLog{} = replay} = Replays.replay(ctx.user, ctx.source, target(ctx))

      assert replay.replayed_from_id == ctx.source.id
      assert replay.status == "success"
      assert replay.final_provider == "test_provider"
      assert replay.final_model == "test-model"

      response = Jason.decode!(replay.response_body)

      assert get_in(response, ["choices", Access.at(0), "message", "content"]) ==
               "Hello from test-model"

      assert Logs.list_replays(ctx.source) |> Enum.map(& &1.id) == [replay.id]
    end

    test "sanitizes the stored request before dispatch", ctx do
      assert {:ok, replay} = Replays.replay(ctx.user, ctx.source, target(ctx))

      request = Jason.decode!(replay.request_body)
      refute Map.has_key?(request, "stream")
      refute Map.has_key?(request, "stream_options")
      refute Map.has_key?(request, "user")
      assert request["model"] == "test-model"
      assert request["temperature"] == 0.7
      assert request["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "blocks replay when the stored request content was truncated", ctx do
      truncated =
        LogsFixtures.log_fixture(ctx.router, %{
          truncation_flags: ["request_text_truncated"],
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "long prompt\n\n... [truncated]"}
              ]
            })
        })

      assert {:error, :truncated} = Replays.replay(ctx.user, truncated, target(ctx))
      assert Logs.list_replays(truncated) == []
    end

    test "allows replay when only the response side was truncated", ctx do
      # truncation_flags don't distinguish request from response truncation;
      # only actual markers in the stored request should block a replay
      response_truncated =
        LogsFixtures.log_fixture(ctx.router, %{
          truncation_flags: ["request_text_truncated"],
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "short prompt"}]})
        })

      assert {:ok, %RequestLog{}} = Replays.replay(ctx.user, response_truncated, target(ctx))
    end

    test "blocks replay of base64-truncated request content", ctx do
      truncated =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "[base64 data: 123456 bytes truncated]"}
              ]
            })
        })

      assert {:error, :truncated} = Replays.replay(ctx.user, truncated, target(ctx))
    end

    test "rejects an undecodable stored body", ctx do
      broken = LogsFixtures.log_fixture(ctx.router, %{request_body: "not json"})

      assert {:error, :invalid_request_body} = Replays.replay(ctx.user, broken, target(ctx))
    end

    test "rejects a missing stored body", ctx do
      empty = LogsFixtures.log_fixture(ctx.router, %{request_body: nil})

      assert {:error, :invalid_request_body} = Replays.replay(ctx.user, empty, target(ctx))
    end

    test "rejects a body without messages", ctx do
      no_messages =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body: Jason.encode!(%{"prompt" => "old-style"})
        })

      assert {:error, :missing_messages} = Replays.replay(ctx.user, no_messages, target(ctx))
    end

    test "rejects a provider key that doesn't belong to the user", ctx do
      other_user = AccountsFixtures.user_fixture()
      other_key = ProvidersFixtures.provider_key_fixture(other_user)

      assert {:error, :provider_key_not_found} =
               Replays.replay(ctx.user, ctx.source, %{
                 provider_key_id: other_key.id,
                 model: "test-model"
               })
    end

    test "rejects a blank model", ctx do
      assert {:error, :invalid_model} = Replays.replay(ctx.user, ctx.source, target(ctx, ""))
    end
  end

  describe "replay/3 with reasoning effort" do
    setup ctx do
      source =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "reasoning_effort" => "low",
              "thinking" => %{"type" => "enabled", "budget_tokens" => 1024},
              "messages" => [%{"role" => "user", "content" => "hi"}]
            })
        })

      %{reasoning_source: source}
    end

    test "explicit effort lands on the step and strips the body's own reasoning params", ctx do
      assert {:ok, replay} =
               Replays.replay(ctx.user, ctx.reasoning_source, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 reasoning_effort: "high"
               })

      request = Jason.decode!(replay.request_body)
      refute Map.has_key?(request, "reasoning_effort")
      refute Map.has_key?(request, "thinking")

      assert [step] = replay.attempted_steps
      assert step["reasoning_effort"] == "high"
    end

    test "no effort keeps the original body's reasoning params (faithful replay)", ctx do
      assert {:ok, replay} =
               Replays.replay(ctx.user, ctx.reasoning_source, target(ctx))

      request = Jason.decode!(replay.request_body)
      assert request["reasoning_effort"] == "low"
      assert request["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}

      assert [step] = replay.attempted_steps
      assert step["reasoning_effort"] == nil
    end

    test "blank effort behaves as as-original", ctx do
      assert {:ok, replay} =
               Replays.replay(ctx.user, ctx.reasoning_source, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 reasoning_effort: ""
               })

      request = Jason.decode!(replay.request_body)
      assert request["reasoning_effort"] == "low"
      assert [step] = replay.attempted_steps
      assert step["reasoning_effort"] == nil
    end

    test "rejects an overlong effort value", ctx do
      assert {:error, :invalid_reasoning_effort} =
               Replays.replay(ctx.user, ctx.reasoning_source, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 reasoning_effort: String.duplicate("x", 33)
               })
    end
  end

  describe "replay/3 from a specific message" do
    setup ctx do
      multi_turn =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body:
            Jason.encode!(%{
              "model" => "original-model",
              "messages" => [
                %{"role" => "user", "content" => "first question"},
                %{"role" => "assistant", "content" => "the failing crud answer"},
                %{"role" => "user", "content" => "second question"}
              ]
            })
        })

      %{multi_turn: multi_turn}
    end

    test "truncates the history at the chosen user message (inclusive)", ctx do
      assert {:ok, replay} =
               Replays.replay(ctx.user, ctx.multi_turn, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 message_index: 0
               })

      assert replay.replayed_from_id == ctx.multi_turn.id
      assert replay.replay_from_index == 0

      request = Jason.decode!(replay.request_body)
      assert request["messages"] == [%{"role" => "user", "content" => "first question"}]
    end

    test "records the anchor even at the last message, where the history isn't shortened",
         ctx do
      assert {:ok, replay} =
               Replays.replay(ctx.user, ctx.multi_turn, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 message_index: 2
               })

      assert replay.replay_from_index == 2
      assert length(Jason.decode!(replay.request_body)["messages"]) == 3
    end

    test "whole-thread replays record no anchor", ctx do
      assert {:ok, replay} = Replays.replay(ctx.user, ctx.multi_turn, target(ctx))
      assert replay.replay_from_index == nil
    end

    test "rejects an index that isn't a user message", ctx do
      assert {:error, :invalid_message_index} =
               Replays.replay(ctx.user, ctx.multi_turn, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 message_index: 1
               })
    end

    test "rejects an out-of-range index", ctx do
      assert {:error, :invalid_message_index} =
               Replays.replay(ctx.user, ctx.multi_turn, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 message_index: 99
               })
    end

    test "storage-truncation markers after the cut don't block a partial replay", ctx do
      log =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "clean question"},
                %{"role" => "assistant", "content" => "big answer\n\n... [truncated]"},
                %{"role" => "user", "content" => "follow-up"}
              ]
            })
        })

      assert {:error, :truncated} = Replays.replay(ctx.user, log, target(ctx))

      assert {:ok, replay} =
               Replays.replay(ctx.user, log, %{
                 provider_key_id: ctx.provider_key.id,
                 model: "test-model",
                 message_index: 0
               })

      request = Jason.decode!(replay.request_body)
      assert [%{"content" => "clean question"}] = request["messages"]
    end
  end

  describe "replay/3 root anchoring" do
    test "replaying a replay anchors to the root and re-runs the root's request", ctx do
      # the chained log's body has drifted — the dispatched request must
      # come from the root so all candidates stay comparable
      child =
        LogsFixtures.log_fixture(ctx.router, %{
          replayed_from_id: ctx.source.id,
          request_body:
            Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "drifted"}]})
        })

      assert {:ok, replay} = Replays.replay(ctx.user, child, target(ctx))

      assert replay.replayed_from_id == ctx.source.id

      request = Jason.decode!(replay.request_body)
      assert request["messages"] == [%{"role" => "user", "content" => "hi"}]
      assert request["temperature"] == 0.7
    end

    test "blockers are evaluated on the root, not the chained log", ctx do
      broken_child =
        LogsFixtures.log_fixture(ctx.router, %{
          replayed_from_id: ctx.source.id,
          request_body: "not json"
        })

      assert {:ok, %RequestLog{}} = Replays.replay(ctx.user, broken_child, target(ctx))
    end
  end

  describe "replay_blocker/1" do
    test "returns nil for a replayable log", ctx do
      assert Replays.replay_blocker(ctx.source) == nil
    end

    test "returns the blocking reason", ctx do
      broken = LogsFixtures.log_fixture(ctx.router, %{request_body: "not json"})
      assert Replays.replay_blocker(broken) == :invalid_request_body
    end

    test "a cut point before the truncated content unblocks the replay", ctx do
      log =
        LogsFixtures.log_fixture(ctx.router, %{
          request_body:
            Jason.encode!(%{
              "messages" => [
                %{"role" => "user", "content" => "clean question"},
                %{"role" => "assistant", "content" => "big answer\n\n... [truncated]"},
                %{"role" => "user", "content" => "follow-up"}
              ]
            })
        })

      assert Replays.replay_blocker(log) == :truncated
      assert Replays.replay_blocker(log, 0) == nil
      assert Replays.replay_blocker(log, 2) == :truncated
    end
  end

  describe "list_targets/1" do
    test "returns configured provider keys with their models", ctx do
      targets = Replays.list_targets(ctx.user)

      assert [%{provider: "test_provider", provider_key: key, models: models}] = targets
      assert key.id == ctx.provider_key.id
      assert Enum.any?(models, &(&1.id == "test-model"))
    end

    test "coding-plan keys offer their plan catalog alongside the provider's", ctx do
      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "moonshot_coding",
          model_id: "k2p6",
          display_name: "Kimi K2.6 (coding plan)"
        })

      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "moonshot",
          model_id: "kimi-k2.6",
          display_name: "Kimi K2.6"
        })

      coding_key =
        ProvidersFixtures.provider_key_fixture(ctx.user, %{provider_slug: "moonshot_coding"})

      target =
        ctx.user
        |> Replays.list_targets()
        |> Enum.find(&(&1.provider_key.id == coding_key.id))

      assert target.provider == "moonshot"
      model_ids = Enum.map(target.models, & &1.id)
      assert "k2p6" in model_ids
      assert "kimi-k2.6" in model_ids
    end

    test "Codex keys offer models from the OpenAI catalog", ctx do
      {:ok, _} =
        DodoRouter.Models.create_model(%{
          provider_slug: "openai",
          model_id: "gpt-5.6-sol",
          display_name: "GPT-5.6 Sol"
        })

      codex_key =
        ProvidersFixtures.provider_key_fixture(ctx.user, %{provider_slug: "openai-codex"})

      target =
        ctx.user
        |> Replays.list_targets()
        |> Enum.find(&(&1.provider_key.id == codex_key.id))

      assert Enum.any?(target.models, &(&1.id == "gpt-5.6-sol"))
    end

    test "returns no targets for a user without keys", _ctx do
      keyless_user = AccountsFixtures.user_fixture()
      assert Replays.list_targets(keyless_user) == []
    end
  end

  describe "deltas/2" do
    test "computes directional metric deltas", ctx do
      {:ok, replay} = Replays.replay(ctx.user, ctx.source, target(ctx))
      deltas = Replays.deltas(ctx.source, replay)

      latency = Enum.find(deltas, &(&1.key == :latency_ms))
      assert latency.original == 1000
      assert is_integer(latency.replay)
      assert latency.direction in [:better, :worse, :even]

      cost = Enum.find(deltas, &(&1.key == :estimated_cost_usd))
      assert cost.direction == :unknown
    end

    test "treats nil metrics as unknown, not improvements", ctx do
      {:ok, replay} = Replays.replay(ctx.user, ctx.source, target(ctx))
      deltas = Replays.deltas(%{ctx.source | latency_ms: nil}, replay)

      latency = Enum.find(deltas, &(&1.key == :latency_ms))
      assert latency.direction == :unknown
      assert latency.delta_pct == nil
    end
  end
end
