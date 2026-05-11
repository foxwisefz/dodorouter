defmodule DodoRouter.Activity do
  @moduledoc """
  Tracks in-flight requests per router for real-time activity display.

  GenServer that maintains state of active requests. No persistence,
  no TTL - requests are explicitly added and removed via event handlers.
  State is keyed by router_id since router IDs are globally unique.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Track a new request as active on primary provider.
  """
  def request_started(router_id, request_id) do
    GenServer.cast(__MODULE__, {:request_started, router_id, request_id})
  end

  @doc """
  Transition a request from primary to fallback status.
  """
  def step_started(router_id, request_id, step_index) when step_index > 0 do
    GenServer.cast(__MODULE__, {:step_started, router_id, request_id, step_index})
  end

  @doc """
  Remove a completed request from tracking.
  """
  def request_completed(router_id, request_id) do
    GenServer.cast(__MODULE__, {:request_completed, router_id, request_id})
  end

  @doc """
  Get activity counts for a specific router.
  Returns {primary_count, fallback_count}.
  """
  def get_router_counts(router_id) do
    GenServer.call(__MODULE__, {:get_router_counts, router_id})
  end

  @doc """
  Get activity counts for multiple routers at once.
  Returns %{router_id => {primary_count, fallback_count}}.
  """
  def get_routers_counts(router_ids) do
    GenServer.call(__MODULE__, {:get_routers_counts, router_ids})
  end

  @doc """
  Get total active request count across given routers.
  """
  def get_total_active(router_ids) do
    GenServer.call(__MODULE__, {:get_total_active, router_ids})
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:request_started, router_id, request_id}, state) do
    router_map = Map.get(state, router_id, %{})
    new_router_map = Map.put(router_map, request_id, :primary)
    {:noreply, Map.put(state, router_id, new_router_map)}
  end

  @impl true
  def handle_cast({:step_started, router_id, request_id, _step_index}, state) do
    router_map = Map.get(state, router_id, %{})

    new_router_map =
      Map.update(router_map, request_id, :fallback, fn
        :primary -> :fallback
        status -> status
      end)

    {:noreply, Map.put(state, router_id, new_router_map)}
  end

  @impl true
  def handle_cast({:request_completed, router_id, request_id}, state) do
    router_map = Map.get(state, router_id, %{})
    {_, new_router_map} = Map.pop(router_map, request_id)

    new_state =
      if map_size(new_router_map) == 0 do
        Map.delete(state, router_id)
      else
        Map.put(state, router_id, new_router_map)
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_router_counts, router_id}, _from, state) do
    requests = Map.get(state, router_id, %{})

    primary = Enum.count(requests, fn {_, status} -> status == :primary end)
    fallback = Enum.count(requests, fn {_, status} -> status == :fallback end)

    {:reply, {primary, fallback}, state}
  end

  @impl true
  def handle_call({:get_routers_counts, router_ids}, _from, state) do
    result =
      Enum.into(router_ids, %{}, fn router_id ->
        requests = Map.get(state, router_id, %{})

        primary = Enum.count(requests, fn {_, status} -> status == :primary end)
        fallback = Enum.count(requests, fn {_, status} -> status == :fallback end)

        {router_id, {primary, fallback}}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_total_active, router_ids}, _from, state) do
    count =
      Enum.reduce(router_ids, 0, fn router_id, acc ->
        requests = Map.get(state, router_id, %{})
        acc + map_size(requests)
      end)

    {:reply, count, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    # Activity state is ephemeral (in-flight request counts).
    # During a hot upgrade, we preserve the state so ongoing requests
    # continue to be tracked correctly.
    {:ok, state}
  end
end
