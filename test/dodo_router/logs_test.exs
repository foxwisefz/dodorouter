defmodule DodoRouter.LogsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Logs.RequestLog
  alias DodoRouter.Recordings
  alias DodoRouter.Repo
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

  # Logs.create_log/1 always stamps inserted_at with the current time, so
  # timeseries tests that need logs in specific buckets must insert directly.
  defp insert_log_at(router, inserted_at, attrs \\ %{}) do
    attrs =
      router
      |> LogsFixtures.valid_log_attributes(attrs)
      |> Map.put(:inserted_at, inserted_at)

    {:ok, log} =
      %RequestLog{}
      |> RequestLog.changeset(attrs)
      |> Repo.insert()

    log
  end

  defp current_hour_bucket do
    %{DateTime.utc_now() | minute: 0, second: 0, microsecond: {0, 0}}
  end

  describe "create_log/1" do
    test "creates log with session_id" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      session_id = "test-session-#{System.unique_integer([:positive])}"

      {:ok, log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          session_id: session_id,
          final_provider: "test",
          final_model: "test-model"
        })

      assert log.session_id == session_id
    end

    test "creates log with session_name" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      {:ok, log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          session_id: "sess-123",
          session_name: "My Chat Session",
          final_provider: "test",
          final_model: "test-model"
        })

      assert log.session_name == "My Chat Session"
    end

    test "creates log with recording_id" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, recording} = Recordings.start_recording(router, %{name: "Test Recording"})

      {:ok, log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          recording_id: recording.id,
          final_provider: "test",
          final_model: "test-model"
        })

      assert log.recording_id == recording.id
    end

    test "broadcasts log_created message" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      Logs.subscribe_to_logs(router.id)

      {:ok, log} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          final_provider: "test",
          final_model: "test-model"
        })

      assert_receive {:log_created, received_log}
      assert received_log.id == log.id
    end
  end

  describe "list_logs/2" do
    test "keeps evaluation traffic out of ordinary router logs" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      proxy_log = LogsFixtures.log_fixture(router)
      eval_log = LogsFixtures.log_fixture(router, %{traffic_type: "evaluation_candidate"})

      listed_ids = router |> Logs.list_logs() |> Enum.map(& &1.id)

      assert proxy_log.id in listed_ids
      refute eval_log.id in listed_ids
      assert Logs.get_log_by_request_id(eval_log.request_id).id == eval_log.id
    end
  end

  describe "list_sessions/2" do
    test "groups logs by session_id" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      session_id = "session-#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          session_id: session_id,
          final_provider: "test",
          final_model: "test-model"
        })
      end

      sessions = Logs.list_sessions(router)
      session = Enum.find(sessions, &(&1.session_id == session_id))

      assert session
      assert session.request_count == 3
    end

    test "sums actual and list cost per session and filters by :hours" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      LogsFixtures.log_fixture(router, %{
        session_id: "recent-session",
        estimated_cost_usd: Decimal.new("0"),
        list_cost_usd: Decimal.new("0.30")
      })

      LogsFixtures.log_fixture(router, %{
        session_id: "recent-session",
        estimated_cost_usd: Decimal.new("0.05"),
        list_cost_usd: Decimal.new("0.10")
      })

      insert_log_at(router, DateTime.add(DateTime.utc_now(), -48 * 3600, :second), %{
        session_id: "old-session"
      })

      [session] = Logs.list_sessions(router, hours: 24)

      assert session.session_id == "recent-session"
      assert Decimal.eq?(session.total_cost_usd, Decimal.new("0.05"))
      assert Decimal.eq?(session.total_list_cost_usd, Decimal.new("0.40"))

      all_ids = Logs.list_sessions(router) |> Enum.map(& &1.session_id) |> Enum.sort()
      assert all_ids == ["old-session", "recent-session"]
    end
  end

  describe "toggle_favorite/2" do
    test "toggles favorite from false to true and back" do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      refute log.favorite

      {:ok, updated} = Logs.toggle_favorite(user, log.id)
      assert updated.favorite

      {:ok, updated2} = Logs.toggle_favorite(user, log.id)
      refute updated2.favorite
    end

    test "toggles favorite by request_id" do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      log = LogsFixtures.log_fixture(router)

      {:ok, updated} = Logs.toggle_favorite(user, log.request_id)
      assert updated.favorite
    end
  end

  describe "list_logs_for_user/2 favorites filter" do
    test "returns only favorited logs" do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)

      LogsFixtures.log_fixture(router, %{favorite: true, final_provider: "fav-provider"})
      LogsFixtures.log_fixture(router, %{favorite: false, final_provider: "other-provider"})

      logs = Logs.list_logs_for_user(user, favorites_only: true)

      assert length(logs) == 1
      assert hd(logs).final_provider == "fav-provider"
    end
  end

  describe "replay linkage" do
    test "create_log/1 persists replayed_from_id" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      original = LogsFixtures.log_fixture(router)

      {:ok, replay} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          final_provider: "test_provider",
          final_model: "other-model",
          replayed_from_id: original.id
        })

      assert replay.replayed_from_id == original.id
    end

    test "create_log/1 rejects a replayed_from_id that doesn't exist" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      assert {:error, changeset} =
               Logs.create_log(%{
                 router_id: router.id,
                 request_id: Ecto.UUID.generate(),
                 status: "success",
                 replayed_from_id: Ecto.UUID.generate()
               })

      assert %{replayed_from_id: ["does not exist"]} = errors_on(changeset)
    end

    test "list_replays/1 returns replays of a log, oldest first" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      original = LogsFixtures.log_fixture(router)
      other = LogsFixtures.log_fixture(router)

      first =
        LogsFixtures.log_fixture(router, %{
          replayed_from_id: original.id,
          final_model: "model-a",
          inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      second =
        LogsFixtures.log_fixture(router, %{
          replayed_from_id: original.id,
          final_model: "model-b"
        })

      _unrelated = LogsFixtures.log_fixture(router, %{replayed_from_id: other.id})

      assert Logs.list_replays(original) |> Enum.map(& &1.id) == [first.id, second.id]
    end
  end

  describe "replay lineage" do
    test "root_of/1 returns the log itself when it isn't a replay" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      log = LogsFixtures.log_fixture(router)

      assert Logs.root_of(log).id == log.id
    end

    test "root_of/1 walks a chain up to the root" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      root = LogsFixtures.log_fixture(router)
      child = LogsFixtures.log_fixture(router, %{replayed_from_id: root.id})
      grandchild = LogsFixtures.log_fixture(router, %{replayed_from_id: child.id})

      assert Logs.root_of(grandchild).id == root.id
      assert Logs.root_of(child).id == root.id
    end

    test "list_session_responses/2 returns lean maps for the user's session, oldest first" do
      user = AccountsFixtures.user_fixture()
      {router, _api_key} = RoutersFixtures.router_fixture(user)
      session_id = "sess-#{System.unique_integer([:positive])}"

      older =
        LogsFixtures.log_fixture(router, %{
          session_id: session_id,
          inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      newer = LogsFixtures.log_fixture(router, %{session_id: session_id})
      _other_session = LogsFixtures.log_fixture(router, %{session_id: "other"})

      other_user = AccountsFixtures.user_fixture()
      {other_router, _} = RoutersFixtures.router_fixture(other_user)
      _other_users_log = LogsFixtures.log_fixture(other_router, %{session_id: session_id})

      responses = Logs.list_session_responses(user, session_id)

      assert Enum.map(responses, & &1.id) == [older.id, newer.id]

      assert %{final_provider: _, final_model: _, response_body: _, inserted_at: _} =
               hd(responses)

      refute Map.has_key?(hd(responses), :request_body)
    end

    test "replay_counts/1 maps log ids to their replay counts" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      replayed = LogsFixtures.log_fixture(router)
      bare = LogsFixtures.log_fixture(router)

      LogsFixtures.log_fixture(router, %{replayed_from_id: replayed.id})
      LogsFixtures.log_fixture(router, %{replayed_from_id: replayed.id})

      assert Logs.replay_counts([replayed.id, bare.id]) == %{replayed.id => 2}
    end
  end

  describe "list_logs_for_recording/2" do
    test "returns logs for specific recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, recording} = Recordings.start_recording(router, %{name: "Test"})

      {:ok, log1} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          recording_id: recording.id,
          final_provider: "test",
          final_model: "test-model"
        })

      {:ok, _log2} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          recording_id: nil,
          final_provider: "test",
          final_model: "test-model"
        })

      logs = Recordings.list_logs_for_recording(recording)
      assert length(logs) == 1
      assert hd(logs).id == log1.id
    end
  end

  describe "stats/2" do
    test "counts fallback-recovered requests as successful" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      LogsFixtures.log_fixture(router, %{status: "success"})
      LogsFixtures.log_fixture(router, %{status: "fallback"})
      LogsFixtures.log_fixture(router, %{status: "error"})

      stats = Logs.stats(router)

      assert stats.total_requests == 3
      # A fallback means the client still got a successful response —
      # it must count toward the success rate, matching stats_by_provider/2.
      assert stats.successful_requests == 2
      assert stats.fallback_requests == 1
      assert stats.error_requests == 1
    end
  end

  describe "cache_stats/2" do
    test "keeps the hit rate under 100% for Anthropic-style usage" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      # Anthropic reports prompt_tokens as newly-billed input only, so a large
      # cache hit over a tiny billed prompt used to render as e.g. 14752%.
      LogsFixtures.log_fixture(router, %{
        prompt_tokens: 260,
        cache_read_tokens: 38_356,
        cache_write_tokens: 0
      })

      stats = Logs.cache_stats(router)

      assert stats.hit_rate == 99.3
      assert stats.cached_requests == 1
    end
  end

  describe "stats_by_provider/2" do
    test "sums total_cost_usd and cache_read_tokens per provider" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      LogsFixtures.log_fixture(router, %{
        final_provider: "openai",
        estimated_cost_usd: Decimal.new("1.25"),
        cache_read_tokens: 10
      })

      LogsFixtures.log_fixture(router, %{
        final_provider: "openai",
        estimated_cost_usd: Decimal.new("0.75"),
        cache_read_tokens: 20
      })

      LogsFixtures.log_fixture(router, %{
        final_provider: "anthropic",
        estimated_cost_usd: Decimal.new("2.00"),
        cache_read_tokens: 5
      })

      results = Logs.stats_by_provider(router)

      openai = Enum.find(results, &(&1.provider == "openai"))
      anthropic = Enum.find(results, &(&1.provider == "anthropic"))

      assert Decimal.eq?(openai.total_cost_usd, Decimal.new("2.00"))
      assert openai.cache_read_tokens == 30

      assert Decimal.eq?(anthropic.total_cost_usd, Decimal.new("2.00"))
      assert anthropic.cache_read_tokens == 5
    end
  end

  describe "timeseries/2" do
    test "buckets counts, statuses, and cost, zero-filling empty buckets, oldest first" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      current_bucket = current_hour_bucket()
      earlier_bucket = DateTime.add(current_bucket, -2 * 3600, :second)

      insert_log_at(router, current_bucket, %{
        status: "success",
        estimated_cost_usd: Decimal.new("1.50")
      })

      insert_log_at(router, current_bucket, %{
        status: "error",
        estimated_cost_usd: Decimal.new("2.50")
      })

      insert_log_at(router, earlier_bucket, %{
        status: "fallback",
        estimated_cost_usd: Decimal.new("0.50")
      })

      buckets = Logs.timeseries(router, bucket: :hour, hours: 3)

      assert length(buckets) >= 3 and length(buckets) <= 4

      bucket_starts = Enum.map(buckets, & &1.bucket)
      assert bucket_starts == Enum.sort(bucket_starts, DateTime)

      current = Enum.find(buckets, &(DateTime.compare(&1.bucket, current_bucket) == :eq))
      earlier = Enum.find(buckets, &(DateTime.compare(&1.bucket, earlier_bucket) == :eq))

      assert current.total == 2
      assert current.success == 1
      assert current.error == 1
      assert current.fallback == 0
      assert Decimal.eq?(current.cost_usd, Decimal.new("4.00"))

      assert earlier.total == 1
      assert earlier.fallback == 1
      assert Decimal.eq?(earlier.cost_usd, Decimal.new("0.50"))

      empty_buckets = buckets -- [current, earlier]
      assert Enum.all?(empty_buckets, &(&1.total == 0))
    end
  end

  describe "spend_timeseries/2" do
    test "pivots spend by provider into sorted series with zero-filled buckets" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      current_bucket = current_hour_bucket()
      earlier_bucket = DateTime.add(current_bucket, -2 * 3600, :second)

      insert_log_at(router, current_bucket, %{
        final_provider: "alpha",
        estimated_cost_usd: Decimal.new("1.00")
      })

      insert_log_at(router, earlier_bucket, %{
        final_provider: "beta",
        estimated_cost_usd: Decimal.new("2.00")
      })

      %{buckets: buckets, series: series} = Logs.spend_timeseries(router, bucket: :hour, hours: 3)

      assert is_list(buckets)
      assert Enum.map(series, & &1.provider) == ["alpha", "beta"]

      current_index = Enum.find_index(buckets, &(DateTime.compare(&1, current_bucket) == :eq))
      earlier_index = Enum.find_index(buckets, &(DateTime.compare(&1, earlier_bucket) == :eq))

      alpha = Enum.find(series, &(&1.provider == "alpha"))
      beta = Enum.find(series, &(&1.provider == "beta"))

      assert length(alpha.values) == length(buckets)
      assert length(beta.values) == length(buckets)

      assert Decimal.eq?(Enum.at(alpha.values, current_index), Decimal.new("1.00"))
      assert Decimal.eq?(Enum.at(beta.values, earlier_index), Decimal.new("2.00"))

      # zero-filled elsewhere
      assert Decimal.eq?(Enum.at(alpha.values, earlier_index), Decimal.new(0))
      assert Decimal.eq?(Enum.at(beta.values, current_index), Decimal.new(0))
    end
  end

  describe "list-price (would-cost) sums" do
    test "plan traffic with zero actual cost still carries list_cost_usd through every aggregate" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      current_bucket = current_hour_bucket()

      # Subscription key pattern: marginal cost 0, list price recorded
      insert_log_at(router, current_bucket, %{
        final_provider: "openai-codex",
        final_model: "chatgpt-5.5",
        estimated_cost_usd: Decimal.new("0"),
        list_cost_usd: Decimal.new("0.42")
      })

      # Cost never computed at all (no list price either)
      insert_log_at(router, current_bucket, %{
        final_provider: "openai-codex",
        final_model: "chatgpt-5.5",
        estimated_cost_usd: nil,
        list_cost_usd: Decimal.new("0.08")
      })

      %{buckets: buckets, series: [codex]} =
        Logs.spend_timeseries(router, bucket: :hour, hours: 2)

      idx = Enum.find_index(buckets, &(DateTime.compare(&1, current_bucket) == :eq))

      assert codex.provider == "openai-codex"
      assert Decimal.eq?(Enum.at(codex.values, idx), Decimal.new("0"))
      assert Decimal.eq?(Enum.at(codex.list_values, idx), Decimal.new("0.50"))

      stats = Logs.stats(router, hours: 2)
      assert Decimal.eq?(stats.total_cost_usd, Decimal.new("0"))
      assert Decimal.eq?(stats.total_list_cost_usd, Decimal.new("0.50"))

      [prov] = Logs.stats_by_provider(router, hours: 2)
      assert Decimal.eq?(prov.total_list_cost_usd, Decimal.new("0.50"))

      [model] = Logs.spend_by_model(router, hours: 2)
      assert model.model == "chatgpt-5.5"
      assert Decimal.eq?(model.list_cost_usd, Decimal.new("0.50"))

      ts = Logs.timeseries(router, bucket: :hour, hours: 2)
      bucket_row = Enum.find(ts, &(DateTime.compare(&1.bucket, current_bucket) == :eq))
      assert Decimal.eq?(bucket_row.list_cost_usd, Decimal.new("0.50"))
    end
  end

  describe "latency_timeseries/2" do
    test "computes p50 per bucket and leaves empty buckets nil" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      current_bucket = current_hour_bucket()

      insert_log_at(router, current_bucket, %{latency_ms: 100})
      insert_log_at(router, current_bucket, %{latency_ms: 200})
      insert_log_at(router, current_bucket, %{latency_ms: 300})

      buckets = Logs.latency_timeseries(router, bucket: :hour, hours: 3)

      current = Enum.find(buckets, &(DateTime.compare(&1.bucket, current_bucket) == :eq))
      others = buckets -- [current]

      assert_in_delta current.p50, 200, 0.01
      assert Enum.all?(others, &is_nil(&1.p50))
    end
  end

  describe "spend_by_model/2" do
    test "orders models by spend descending" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      LogsFixtures.log_fixture(router, %{
        final_model: "cheap-model",
        final_provider: "openai",
        estimated_cost_usd: Decimal.new("0.10"),
        total_tokens: 100
      })

      LogsFixtures.log_fixture(router, %{
        final_model: "pricey-model",
        final_provider: "anthropic",
        estimated_cost_usd: Decimal.new("5.00"),
        total_tokens: 200
      })

      results = Logs.spend_by_model(router)

      assert Enum.map(results, & &1.model) == ["pricey-model", "cheap-model"]

      pricey = Enum.find(results, &(&1.model == "pricey-model"))
      assert pricey.provider == "anthropic"
      assert pricey.total_requests == 1
      assert pricey.total_tokens == 200
      assert Decimal.eq?(pricey.cost_usd, Decimal.new("5.00"))
    end
  end
end
