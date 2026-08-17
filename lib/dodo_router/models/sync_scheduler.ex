defmodule DodoRouter.Models.SyncScheduler do
  @moduledoc """
  Runs the models.dev catalog sync on a timer.

  `Models.Sync.sync_from_models_dev/0` had no callers anywhere in the repo:
  no scheduler, no mix task, no button. The only way it ever ran was someone
  typing it into a remote console, which means the catalog was current only
  as often as somebody remembered — 40 days, when this was written.

  A stale catalog is not a cosmetic problem. `list_cost_usd` is computed from
  these prices and is the number the whole cost comparison rests on, so an
  old table produces confident, wrong money. Retired models stay on offer,
  and new ones never appear.

  Syncing is safe to automate because it only ever upserts: costs are stored
  per request log when the request runs, so a price change cannot rewrite
  history, and nothing here deletes a row.
  """

  use GenServer

  require Logger

  alias DodoRouter.Models.Sync

  # Long enough that a boot loop can't hammer models.dev, short enough that a
  # fresh deploy has a current catalog within the minute.
  @initial_delay_ms :timer.seconds(30)
  @interval_ms :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs a sync now, outside the schedule."
  def sync_now, do: GenServer.cast(__MODULE__, :sync)

  @impl true
  def init(opts) do
    if enabled?() do
      schedule(Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    end

    {:ok, %{last_result: nil}}
  end

  @impl true
  def handle_info(:sync, state) do
    schedule(@interval_ms)
    {:noreply, %{state | last_result: run_sync()}}
  end

  @impl true
  def handle_cast(:sync, state), do: {:noreply, %{state | last_result: run_sync()}}

  # State is a plain map with one key, but a hot upgrade that changes it
  # still needs somewhere to migrate from.
  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  defp run_sync do
    case Sync.sync_from_models_dev() do
      {:ok, count} ->
        Logger.info("models.dev sync updated #{count} model(s)")
        {:ok, count}

      {:error, reason} ->
        # Logged, never raised: a failed sync leaves the previous catalog in
        # place, which is exactly what should happen. Crashing the scheduler
        # would stop every later attempt too.
        Logger.error("models.dev sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule(delay), do: Process.send_after(self(), :sync, delay)

  @doc """
  Whether the timer runs at all.

  Off under the SQL sandbox — a timer firing mid-suite would write outside
  any test's ownership — and switchable off in config for a deployment that
  wants a pinned catalog.
  """
  def enabled? do
    not Application.get_env(:dodo_router, :sql_sandbox, false) and
      Application.get_env(:dodo_router, :models_sync_enabled, true)
  end
end
