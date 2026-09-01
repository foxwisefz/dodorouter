defmodule DodoRouter.Logs.PendingLog do
  @moduledoc """
  The display payload for a request that is in flight and therefore has no
  `request_logs` row yet.

  Built once at dispatch: broadcast as `:log_pending` for LiveViews already
  mounted, and stored in `DodoRouter.Activity` so a LiveView that mounts (or
  resets its stream) mid-request can still render the row — otherwise the
  sidebar's activity count shows a request the logs list cannot.
  """

  def build(router, request_id, first_step, streaming) do
    %{
      id: nil,
      request_id: request_id,
      router_id: router.id,
      user_id: router.user_id,
      router: router,
      status: "pending",
      call_type: nil,
      final_provider: first_step.provider,
      final_model: first_step.model,
      streaming: streaming,
      inserted_at: DateTime.utc_now(),
      # Fields needed for display - use string keys to match template expectations
      attempted_steps: [%{"provider" => first_step.provider, "model" => first_step.model}]
    }
  end

  @doc """
  A fallback fired mid-request: the row announced with the first step's
  provider is now being served by the backup. Marks the failed hop and shows
  the step actually running, so the switch is visible while in flight.
  """
  def apply_fallback(pending, update) do
    steps =
      pending.attempted_steps
      |> List.update_at(-1, &Map.put(&1, "status", "error"))
      |> Kernel.++([
        %{
          "provider" => update.provider,
          "model" => update.model,
          "plan_type" => update.plan_type
        }
      ])

    pending
    |> Map.put(:final_provider, update.provider)
    |> Map.put(:final_model, update.model)
    |> Map.put(:attempted_steps, steps)
  end
end
