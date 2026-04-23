defmodule DodoRouter.LogsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Logs
  alias DodoRouter.Recordings
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
