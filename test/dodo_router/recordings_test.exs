defmodule DodoRouter.RecordingsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Recordings
  alias DodoRouter.RoutersFixtures

  describe "start_recording/2" do
    test "creates a recording with status 'recording'" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      {:ok, recording} = Recordings.start_recording(router, %{name: "Test Recording"})

      assert recording.name == "Test Recording"
      assert recording.status == "recording"
      assert recording.started_at
      assert is_nil(recording.stopped_at)
    end

    test "stops existing recording when starting new one" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      {:ok, first} = Recordings.start_recording(router, %{name: "First"})
      {:ok, second} = Recordings.start_recording(router, %{name: "Second"})

      # Reload first recording
      first = Recordings.get_recording!(first.id)

      assert first.status == "stopped"
      assert first.stopped_at
      assert second.status == "recording"
    end

    test "creates recording without name" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      {:ok, recording} = Recordings.start_recording(router)

      assert is_nil(recording.name)
      assert recording.status == "recording"
    end
  end

  describe "stop_recording/1" do
    test "stops active recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, recording} = Recordings.start_recording(router, %{name: "Test"})

      {:ok, stopped} = Recordings.stop_recording(router)

      assert stopped.id == recording.id
      assert stopped.status == "stopped"
      assert stopped.stopped_at
    end

    test "returns error when no active recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      assert {:error, :not_found} = Recordings.stop_recording(router)
    end
  end

  describe "get_active_recording/1" do
    test "returns active recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, recording} = Recordings.start_recording(router, %{name: "Active"})

      active = Recordings.get_active_recording(router)

      assert active.id == recording.id
    end

    test "returns nil when no active recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()

      assert is_nil(Recordings.get_active_recording(router))
    end

    test "returns nil after recording is stopped" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, _recording} = Recordings.start_recording(router, %{name: "Test"})
      {:ok, _stopped} = Recordings.stop_recording(router)

      assert is_nil(Recordings.get_active_recording(router))
    end
  end

  describe "list_recordings/2" do
    test "lists recordings for router" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, _r1} = Recordings.start_recording(router, %{name: "First"})
      {:ok, _r2} = Recordings.start_recording(router, %{name: "Second"})

      recordings = Recordings.list_recordings(router)

      assert length(recordings) == 2
      assert Enum.any?(recordings, &(&1.name == "First"))
      assert Enum.any?(recordings, &(&1.name == "Second"))
    end

    test "does not list recordings from other routers" do
      {router1, _} = RoutersFixtures.router_fixture()
      {router2, _} = RoutersFixtures.router_fixture()

      {:ok, _} = Recordings.start_recording(router1, %{name: "Router1 Recording"})
      {:ok, _} = Recordings.start_recording(router2, %{name: "Router2 Recording"})

      recordings = Recordings.list_recordings(router1)

      assert length(recordings) == 1
      assert hd(recordings).name == "Router1 Recording"
    end
  end

  describe "recording_stats/1" do
    test "returns stats for recording" do
      {router, _api_key} = RoutersFixtures.router_fixture()
      {:ok, recording} = Recordings.start_recording(router, %{name: "Stats Test"})

      alias DodoRouter.Logs

      {:ok, _} =
        Logs.create_log(%{
          router_id: router.id,
          request_id: Ecto.UUID.generate(),
          status: "success",
          recording_id: recording.id,
          final_provider: "test",
          final_model: "test-model",
          total_tokens: 100,
          prompt_tokens: 60,
          completion_tokens: 40,
          latency_ms: 500
        })

      stats = Recordings.recording_stats(recording)

      assert stats.request_count == 1
      assert stats.total_tokens == 100
      assert stats.successful_requests == 1
    end
  end
end
