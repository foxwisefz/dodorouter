defmodule DodoRouter.Logs.CacheRegressionTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Logs.CacheRegression
  alias DodoRouter.Logs.RequestLog

  # Anthropic-convention rows: `prompt_tokens` counts only the input that was
  # neither read from nor written to cache, so total input is the sum.
  defp turn(opts) do
    %RequestLog{
      id: opts[:id] || Ecto.UUID.generate(),
      inserted_at: opts[:at] || ~U[2026-08-11 12:00:00.000000Z],
      final_model: opts[:model] || "claude-opus-5",
      final_provider: opts[:provider] || "anthropic",
      prompt_tokens: opts[:prompt],
      cache_read_tokens: opts[:read],
      cache_write_tokens: opts[:write]
    }
  end

  # A session where each turn extends the cached prefix: the read grows with
  # the conversation.
  defp healthy_session do
    for {read, i} <- Enum.with_index([10_000, 12_000, 14_000, 16_000, 18_000]) do
      turn(
        read: read,
        prompt: 300,
        at: DateTime.add(~U[2026-08-11 12:00:00.000000Z], i * 30, :second)
      )
    end
  end

  # The AGENTS.md breakpoint bug: the read pins at the last stable breakpoint
  # while everything after it is rewritten every turn.
  defp regressed_session do
    pinned =
      for {prompt, i} <- Enum.with_index([9_000, 12_000, 15_000, 18_000], 2) do
        turn(
          read: 38_000,
          prompt: prompt,
          at: DateTime.add(~U[2026-08-11 12:00:00.000000Z], i * 30, :second)
        )
      end

    [
      turn(read: 20_000, prompt: 400, at: ~U[2026-08-11 12:00:00.000000Z]),
      turn(read: 38_000, prompt: 400, at: ~U[2026-08-11 12:00:30.000000Z])
      | pinned
    ]
  end

  describe "classify/1" do
    test "a session whose cached prefix keeps growing is healthy" do
      assert CacheRegression.classify(healthy_session()) == :healthy
    end

    test "flags a read pinned while the conversation keeps growing" do
      assert {:regressed, finding} = CacheRegression.classify(regressed_session())
      assert finding.pinned_read == 38_000
    end

    test "names the turn where it diverged" do
      logs = regressed_session()
      # Index 1 is the last turn that still extended the cache; index 2 is the
      # first that should have and didn't.
      diverged = Enum.at(logs, 2)

      assert {:regressed, finding} = CacheRegression.classify(logs)
      assert finding.diverged_at.id == diverged.id
      assert finding.through.id == List.last(logs).id
      assert finding.turns == 4
    end

    test "reports the input that was rewritten instead of read from cache" do
      assert {:regressed, finding} = CacheRegression.classify(regressed_session())
      # 9k -> 18k of billed input across the stall.
      assert finding.uncached_growth == 9_000
    end

    test "a conversation that barely grows is not a regression" do
      # A pinned read means nothing when there is almost nothing new to cache;
      # Anthropic will not create an entry below its minimum prefix anyway.
      logs =
        for {prompt, i} <- Enum.with_index([300, 310, 320, 330]) do
          turn(
            read: 38_000,
            prompt: prompt,
            at: DateTime.add(~U[2026-08-11 12:00:00.000000Z], i * 30, :second)
          )
        end

      assert CacheRegression.classify(logs) == :healthy
    end

    test "a switch of model resets the cache and does not count as a stall" do
      # Caches are model-scoped, so the read starting over is expected.
      logs = [
        turn(read: 20_000, prompt: 400, model: "claude-opus-5"),
        turn(read: 0, prompt: 9_000, model: "claude-sonnet-5", at: at(30)),
        turn(read: 0, prompt: 12_000, model: "claude-opus-5", at: at(60)),
        turn(read: 0, prompt: 15_000, model: "claude-sonnet-5", at: at(90)),
        turn(read: 0, prompt: 18_000, model: "claude-opus-5", at: at(120))
      ]

      assert CacheRegression.classify(logs) == :healthy
    end

    test "a gap longer than the cache lifetime is an expiry, not a regression" do
      logs = [
        turn(read: 20_000, prompt: 400),
        turn(read: 0, prompt: 9_000, at: at(2 * 60 * 60)),
        turn(read: 0, prompt: 12_000, at: at(2 * 60 * 60 + 30)),
        turn(read: 0, prompt: 15_000, at: at(2 * 60 * 60 + 60)),
        turn(read: 0, prompt: 18_000, at: at(2 * 60 * 60 + 90))
      ]

      assert CacheRegression.classify(logs) == :healthy
    end

    test "a cache that collapses to zero after hitting is a regression" do
      logs = [
        turn(read: 20_000, prompt: 400),
        turn(read: 30_000, prompt: 400, at: at(30)),
        turn(read: 0, prompt: 31_000, at: at(60)),
        turn(read: 0, prompt: 34_000, at: at(90)),
        turn(read: 0, prompt: 37_000, at: at(120))
      ]

      assert {:regressed, finding} = CacheRegression.classify(logs)
      assert finding.pinned_read == 0
    end

    test "a session that never cached at all is not a regression" do
      # No provider-side caching, or a client that never set a breakpoint —
      # there is no working state to have regressed from.
      logs =
        for {prompt, i} <- Enum.with_index([9_000, 12_000, 15_000, 18_000]) do
          turn(read: 0, prompt: prompt, at: at(i * 30))
        end

      assert CacheRegression.classify(logs) == :healthy
    end

    test "too few comparable turns to judge" do
      assert CacheRegression.classify([]) == :insufficient_data
      assert CacheRegression.classify(Enum.take(healthy_session(), 2)) == :insufficient_data
    end

    test "turns with no usage recorded are skipped rather than breaking the run" do
      # A failed attempt logs no tokens; it says nothing about the cache.
      logs = List.insert_at(regressed_session(), 3, turn(prompt: nil, read: nil, at: at(75)))

      assert {:regressed, _} = CacheRegression.classify(logs)
    end

    test "OpenAI-convention rows are read with the right arithmetic" do
      # There, prompt_tokens is the total input and cache reads are a subset of
      # it — subtracting again would report growth that never happened.
      logs =
        for {prompt, i} <- Enum.with_index([40_000, 40_100, 40_200, 40_300]) do
          turn(read: 38_000, prompt: prompt, at: at(i * 30))
        end

      assert CacheRegression.classify(logs) == :healthy
    end
  end

  defp at(seconds), do: DateTime.add(~U[2026-08-11 12:00:00.000000Z], seconds, :second)
end
