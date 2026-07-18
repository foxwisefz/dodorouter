defmodule DodoRouter.Activity do
  @moduledoc """
  Tracks in-flight requests per router for real-time activity display.

  GenServer that maintains state of active requests, keyed by router_id
  since router IDs are globally unique. Requests are explicitly added and
  removed via event handlers, and each entry's owner process is monitored:
  if the owner dies without reporting completion (adapter crash, kill
  during hot upgrade, client abort), its entries are dropped automatically
  so the counts can never leak.

  State shape:

      %{
        routers: %{router_id => %{request_id => :primary | :fallback}},
        owners: %{pid => %{ref: reference(), entries: MapSet.t({router_id, request_id})}}
      }
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Track a new request as active on primary provider.

  The calling process is monitored; entries whose owner dies are removed
  automatically.
  """
  def request_started(router_id, request_id) do
    GenServer.cast(__MODULE__, {:request_started, router_id, request_id, self()})
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
  def init(_state) do
    {:ok, %{routers: %{}, owners: %{}}}
  end

  @impl true
  def handle_cast({:request_started, router_id, request_id, owner}, state) do
    router_map = state.routers |> Map.get(router_id, %{}) |> Map.put(request_id, :primary)

    {:noreply,
     %{
       state
       | routers: Map.put(state.routers, router_id, router_map),
         owners: add_owner_entry(state.owners, owner, {router_id, request_id})
     }}
  end

  @impl true
  def handle_cast({:step_started, router_id, request_id, _step_index}, state) do
    router_map =
      state.routers
      |> Map.get(router_id, %{})
      |> Map.update(request_id, :fallback, fn
        :primary -> :fallback
        status -> status
      end)

    {:noreply, %{state | routers: Map.put(state.routers, router_id, router_map)}}
  end

  @impl true
  def handle_cast({:request_completed, router_id, request_id}, state) do
    {:noreply,
     %{
       state
       | routers: remove_request(state.routers, router_id, request_id),
         owners: remove_owner_entry(state.owners, {router_id, request_id})
     }}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.owners, pid) do
      {nil, _owners} ->
        {:noreply, state}

      {%{entries: entries}, owners} ->
        routers =
          Enum.reduce(entries, state.routers, fn {router_id, request_id}, acc ->
            remove_request(acc, router_id, request_id)
          end)

        {:noreply, %{state | routers: routers, owners: owners}}
    end
  end

  @impl true
  def handle_call({:get_router_counts, router_id}, _from, state) do
    requests = Map.get(state.routers, router_id, %{})

    primary = Enum.count(requests, fn {_, status} -> status == :primary end)
    fallback = Enum.count(requests, fn {_, status} -> status == :fallback end)

    {:reply, {primary, fallback}, state}
  end

  @impl true
  def handle_call({:get_routers_counts, router_ids}, _from, state) do
    result =
      Enum.into(router_ids, %{}, fn router_id ->
        requests = Map.get(state.routers, router_id, %{})

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
        requests = Map.get(state.routers, router_id, %{})
        acc + map_size(requests)
      end)

    {:reply, count, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    # Hot upgrade from the legacy shape %{router_id => %{request_id => status}}.
    # Legacy entries carry no owner pid, so they are only removed by an explicit
    # request_completed: requests in flight during the upgrade still resolve
    # normally, while entries already leaked before the upgrade must be cleared
    # manually (:sys.replace_state).
    if Map.has_key?(state, :routers) do
      {:ok, state}
    else
      {:ok, %{routers: state, owners: %{}}}
    end
  end

  defp add_owner_entry(owners, owner, entry) do
    case owners do
      %{^owner => %{entries: entries} = record} ->
        Map.put(owners, owner, %{record | entries: MapSet.put(entries, entry)})

      _ ->
        ref = Process.monitor(owner)
        Map.put(owners, owner, %{ref: ref, entries: MapSet.new([entry])})
    end
  end

  defp remove_owner_entry(owners, entry) do
    found =
      Enum.find(owners, fn {_pid, %{entries: entries}} -> MapSet.member?(entries, entry) end)

    case found do
      nil ->
        owners

      {pid, %{ref: ref, entries: entries} = record} ->
        entries = MapSet.delete(entries, entry)

        if MapSet.size(entries) == 0 do
          Process.demonitor(ref, [:flush])
          Map.delete(owners, pid)
        else
          Map.put(owners, pid, %{record | entries: entries})
        end
    end
  end

  defp remove_request(routers, router_id, request_id) do
    {_, router_map} = routers |> Map.get(router_id, %{}) |> Map.pop(request_id)

    if map_size(router_map) == 0 do
      Map.delete(routers, router_id)
    else
      Map.put(routers, router_id, router_map)
    end
  end
end
