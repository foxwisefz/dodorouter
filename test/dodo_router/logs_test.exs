defmodule DodoRouter.LogsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Recordings
  alias DodoRouter.AccountsFixtures
  alias DodoRouter.LogsFixtures
  alias DodoRouter.RoutersFixtures

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
end
