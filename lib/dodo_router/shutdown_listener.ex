defmodule DodoRouter.ShutdownListener do
  @moduledoc """
  Listens for SIGTERM and sets a flag so health checks return 503.
  This tells the load balancer to stop sending new traffic while
  existing requests drain.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def shutting_down? do
    GenServer.call(__MODULE__, :shutting_down?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_) do
    # Register for SIGTERM
    :os.set_signal(:sigterm, :handle)
    {:ok, %{shutting_down: false}}
  end

  @impl true
  def handle_call(:shutting_down?, _from, state) do
    {:reply, state.shutting_down, state}
  end

  @impl true
  def handle_info({:signal, :sigterm}, state) do
    IO.puts("[ShutdownListener] SIGTERM received, marking unhealthy")
    {:noreply, %{state | shutting_down: true}}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end
end
