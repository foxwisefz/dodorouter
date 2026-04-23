defmodule DodoRouter.LogsFixtures do
  @moduledoc """
  Test helpers for creating log entities.
  """

  alias DodoRouter.Logs

  def valid_log_attributes(router, attrs \\ %{}) do
    Enum.into(attrs, %{
      router_id: router.id,
      request_id: Ecto.UUID.generate(),
      status: "success",
      final_provider: "test_provider",
      final_model: "test-model",
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
      latency_ms: 500,
      http_status: 200,
      call_type: "completion"
    })
  end

  def log_fixture(router, attrs \\ %{}) do
    {:ok, log} =
      router
      |> valid_log_attributes(attrs)
      |> Logs.create_log()

    log
  end

  def log_with_session(router, session_id, attrs \\ %{}) do
    log_fixture(router, Map.merge(attrs, %{session_id: session_id}))
  end
end
