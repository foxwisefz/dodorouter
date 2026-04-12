defmodule DodoRouter.Proxy.InflightTracker do
  @moduledoc """
  Tracks in-flight proxy requests using ETS.

  Provides real-time visibility into requests that are currently being processed.
  """

  use GenServer

  @table :inflight_requests

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Registers a request as in-flight.
  """
  def register(request_id, router_id, metadata \\ %{}) do
    entry = %{
      request_id: request_id,
      router_id: router_id,
      started_at: DateTime.utc_now(),
      model: metadata[:model],
      provider: metadata[:provider],
      streaming: metadata[:streaming] || false
    }

    :ets.insert(@table, {request_id, entry})
    broadcast_change(router_id)
    :ok
  end

  @doc """
  Removes a request from in-flight tracking.
  """
  def unregister(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, entry}] ->
        :ets.delete(@table, request_id)
        broadcast_change(entry.router_id)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Updates metadata for an in-flight request (e.g., when provider is determined).
  """
  def update(request_id, updates) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, entry}] ->
        updated = Map.merge(entry, updates)
        :ets.insert(@table, {request_id, updated})
        broadcast_change(entry.router_id)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Lists all in-flight requests for a router.
  """
  def list(router_id) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, entry} -> entry.router_id == router_id end)
    |> Enum.map(fn {_id, entry} -> enrich_entry(entry) end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Returns count of in-flight requests for a router.
  """
  def count(router_id) do
    @table
    |> :ets.tab2list()
    |> Enum.count(fn {_id, entry} -> entry.router_id == router_id end)
  end

  @doc """
  Subscribe to in-flight changes for a router.
  """
  def subscribe(router_id) do
    Phoenix.PubSub.subscribe(DodoRouter.PubSub, topic(router_id))
  end

  @doc """
  Unsubscribe from in-flight changes.
  """
  def unsubscribe(router_id) do
    Phoenix.PubSub.unsubscribe(DodoRouter.PubSub, topic(router_id))
  end

  # Server callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # Private

  defp topic(router_id), do: "router:#{router_id}:inflight"

  defp broadcast_change(router_id) do
    Phoenix.PubSub.broadcast(
      DodoRouter.PubSub,
      topic(router_id),
      {:inflight_changed, router_id}
    )
  end

  defp enrich_entry(entry) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), entry.started_at, :millisecond)
    Map.put(entry, :elapsed_ms, elapsed_ms)
  end
end
