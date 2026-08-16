defmodule DodoRouter.EvaluationsRecordingTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.AccountsFixtures
  alias DodoRouter.Evaluations
  alias DodoRouter.LogsFixtures
  alias DodoRouter.ProvidersFixtures
  alias DodoRouter.Recordings
  alias DodoRouter.RoutersFixtures

  defp evaluable_body(marker) do
    Jason.encode!(%{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "request #{marker}"}]
    })
  end

  defp recording_with_logs(router, count, attrs_fun) do
    {:ok, recording} = Recordings.start_recording(router, %{name: "Capture"})

    logs =
      for i <- 1..count do
        LogsFixtures.log_fixture(
          router,
          Map.merge(%{recording_id: recording.id}, attrs_fun.(i))
        )
      end

    {recording, logs}
  end

  describe "source_logs_from_recording/2" do
    test "selects only replayable logs and counts the excluded by reason" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)

      {recording, _logs} =
        recording_with_logs(router, 3, fn
          1 -> %{request_body: evaluable_body(1)}
          # No request body at all: not replayable.
          _other -> %{}
        end)

      sample = Evaluations.source_logs_from_recording(recording)

      assert sample.total == 3
      assert sample.evaluable == 1
      assert [%{recording_id: recording_id}] = sample.selected
      assert recording_id == recording.id
      assert %{invalid_request_body: 2} = sample.excluded
    end

    test "spreads picks evenly across the capture instead of taking the front" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)

      {recording, logs} =
        recording_with_logs(router, 9, fn i -> %{request_body: evaluable_body(i)} end)

      sample = Evaluations.source_logs_from_recording(recording, cap: 3)

      assert length(sample.selected) == 3
      selected_ids = Enum.map(sample.selected, & &1.id)
      ordered_ids = Enum.map(logs, & &1.id)

      # Endpoints included, middle from the middle — not the first three.
      assert List.first(selected_ids) == List.first(ordered_ids)
      assert List.last(selected_ids) == List.last(ordered_ids)
      assert selected_ids == Enum.map([0, 4, 8], &Enum.at(ordered_ids, &1))
    end

    test "keeps every evaluable log when the capture fits under the cap" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)

      {recording, logs} =
        recording_with_logs(router, 4, fn i -> %{request_body: evaluable_body(i)} end)

      sample = Evaluations.source_logs_from_recording(recording)

      assert Enum.map(sample.selected, & &1.id) == Enum.map(logs, & &1.id)
      assert sample.excluded == %{}
    end
  end

  describe "recording provenance on evaluations" do
    test "create_evaluation stamps recording_id and list_for_recording finds it" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      provider_key = ProvidersFixtures.provider_key_fixture(user)

      {recording, [log | _] = logs} =
        recording_with_logs(router, 2, fn i -> %{request_body: evaluable_body(i)} end)

      assert {:ok, evaluation} =
               Evaluations.create_evaluation(user, log, %{
                 name: "Recording benchmark",
                 criteria: "Answer accurately",
                 judge_model: "test-model",
                 judge_provider_key_id: provider_key.id,
                 candidate_targets: [
                   %{
                     "provider_key_id" => provider_key.id,
                     "provider" => "test_provider",
                     "model" => "test-model"
                   }
                 ],
                 source_log_ids: Enum.map(logs, & &1.id),
                 recording_id: recording.id
               })

      assert evaluation.recording_id == recording.id

      assert [%{id: found_id, run_count: 0}] = Evaluations.list_for_recording(user, recording.id)
      assert found_id == evaluation.id

      # Another user sees nothing for the same recording.
      other = AccountsFixtures.user_fixture()
      assert Evaluations.list_for_recording(other, recording.id) == []
    end
  end

  describe "per-source rankings" do
    alias DodoRouter.Logs.EvaluationRun

    defp run(model, source_log_id, attrs) do
      struct!(
        %EvaluationRun{
          status: "completed",
          candidate_provider: "test_provider",
          candidate_model: model,
          source_log_id: source_log_id
        },
        attrs
      )
    end

    test "each ranking row breaks down per source log, worst first" do
      log_a = Ecto.UUID.generate()
      log_b = Ecto.UUID.generate()
      log_c = Ecto.UUID.generate()

      runs = [
        # Fine on A and B, catastrophic on C — the aggregate hides this.
        run("cheap-model", log_a, score: 90),
        run("cheap-model", log_a, score: 94),
        run("cheap-model", log_b, score: 88),
        run("cheap-model", log_c, score: 20),
        run("cheap-model", log_c, status: "failed", score: nil)
      ]

      assert [%{model: "cheap-model", per_source: per_source}] = Evaluations.rankings(runs)

      assert [
               %{source_log_id: ^log_c, average: 20, min: 20, successful: 1, total: 2},
               %{source_log_id: ^log_b, average: 88},
               %{source_log_id: ^log_a, average: 92}
             ] = per_source

      # A source where every run failed sorts ahead of any scored one.
      runs = runs ++ [run("cheap-model", Ecto.UUID.generate(), status: "failed", score: nil)]
      assert [%{per_source: [worst | _]}] = Evaluations.rankings(runs)
      assert worst.average == nil
      assert worst.total == 1
    end

    test "single-source benchmarks carry no breakdown" do
      log = Ecto.UUID.generate()
      runs = [run("m", log, score: 80), run("m", log, score: 90)]

      assert [%{per_source: []}] = Evaluations.rankings(runs)
    end
  end

  describe "Recordings.get_recording/2" do
    test "resolves only the owner's recording" do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)
      {:ok, recording} = Recordings.start_recording(router)

      assert %{id: id} = Recordings.get_recording(user, recording.id)
      assert id == recording.id
      assert Recordings.get_recording(other, recording.id) == nil
      assert Recordings.get_recording(user, "not-a-uuid") == nil
    end
  end

  describe "Recordings.log_counts/1" do
    test "counts captured logs per recording in one shape" do
      user = AccountsFixtures.user_fixture()
      {router, _key} = RoutersFixtures.router_fixture(user)

      {recording, _logs} = recording_with_logs(router, 3, fn _i -> %{} end)
      {:ok, empty} = Recordings.start_recording(router, %{name: "Empty"})

      counts = Recordings.log_counts([recording.id, empty.id])

      assert counts[recording.id] == 3
      refute Map.has_key?(counts, empty.id)
    end
  end
end
