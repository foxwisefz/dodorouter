defmodule DodoRouter.Evaluations.MonitorSweeper do
  @moduledoc """
  Runs due eval monitors on a timer.

  A monitor without a scheduler is the Models.Sync story again: a decision
  that stays honest only as often as somebody remembers to check. The
  sweep itself is bounded — each due monitor judges at most its
  `sample_size` answers, and a monitor whose judge key is unusable is
  skipped without spending anything.
  """

  use GenServer

  require Logger

  alias DodoRouter.Evaluations

  # The tick is cheaper than a sweep: due-ness is decided per monitor by
  # its own interval_hours, the timer just has to fire often enough that
  # "daily" does not drift into "daily and a half".
  @initial_delay_ms :timer.seconds(60)
  @interval_ms :timer.minutes(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Sweeps all due monitors now, outside the schedule."
  def sweep_now, do: GenServer.cast(__MODULE__, :sweep)

  @impl true
  def init(opts) do
    if enabled?() do
      schedule(Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule(@interval_ms)
    run_due()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sweep, state) do
    run_due()
    {:noreply, state}
  end

  # Stateless today, but a hot upgrade that grows the state still needs
  # somewhere to migrate from.
  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  defp run_due do
    for monitor <- Evaluations.due_monitors() do
      sweep_one(monitor)
    end
  end

  defp sweep_one(monitor) do
    case Evaluations.sweep_monitor(monitor) do
      {:ok, _monitor} ->
        :ok

      {:error, :judge_unusable} ->
        Logger.warning("eval monitor #{monitor.id} skipped: judge key unusable")
    end
  rescue
    # Logged, never raised: one broken monitor must not stop the rest, and
    # crashing the sweeper would stop every later sweep too.
    exception ->
      Logger.error("eval monitor #{monitor.id} sweep crashed: #{Exception.message(exception)}")
  end

  defp schedule(delay), do: Process.send_after(self(), :sweep, delay)

  @doc """
  Whether the timer runs at all. Off under the SQL sandbox — a timer
  firing mid-suite would write outside any test's ownership.
  """
  def enabled? do
    not Application.get_env(:dodo_router, :sql_sandbox, false) and
      Application.get_env(:dodo_router, :eval_monitor_sweep_enabled, true)
  end
end
