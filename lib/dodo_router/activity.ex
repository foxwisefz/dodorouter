defmodule DodoRouter.Activity do
  @moduledoc """
  Tracks in-flight requests per router for real-time activity display.

  GenServer that maintains state of active requests, keyed by router_id
  since router IDs are globally unique. Requests are explicitly added and
  removed via event handlers, and each entry's owner process is monitored:
  if the owner dies without reporting completion (adapter crash, kill
  during hot upgrade, client abort), its entries are dropped automatically
  so the counts can never leak.

  Each entry also carries the request's pending-log display payload (see
  `DodoRouter.Logs.PendingLog`), so a LiveView mounting mid-request can list
  the in-flight rows it missed the `:log_pending` broadcast for.

  State shape:

      %{
        routers: %{router_id => %{request_id => %{status: :primary | :fallback, log: map() | nil}}},
        owners: %{pid => %{ref: reference(), entries: MapSet.t({router_id, request_id})}}
      }
  """

  use GenServer

  alias DodoRouter.Logs.PendingLog

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Track a new request as active on primary provider.

  `pending_log` is the display payload served back by `list_pending/1` while
  the request is in flight.

  The calling process is monitored; entries whose owner dies are removed
  automatically.
  """
  def request_started(router_id, request_id, pending_log \\ nil) do
    GenServer.cast(__MODULE__, {:request_started, router_id, request_id, pending_log, self()})
  end

  @doc """
  Transition a request from primary to fallback status.

  `step_info` (`%{provider:, model:, plan_type:}`) moves the stored pending
  log onto the step now serving, so a list built mid-fallback doesn't name a
  provider that already failed.
  """
  def step_started(router_id, request_id, step_index, step_info \\ nil) when step_index > 0 do
    GenServer.cast(__MODULE__, {:step_started, router_id, request_id, step_index, step_info})
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

  @doc """
  Pending-log payloads for every in-flight request on the given routers,
  newest first. Entries tracked without a payload are omitted.
  """
  def list_pending(router_ids) do
    GenServer.call(__MODULE__, {:list_pending, router_ids})
  end

  @impl true
  def init(_state) do
    {:ok, %{routers: %{}, owners: %{}}}
  end

  @impl true
  def handle_cast({:request_started, router_id, request_id, pending_log, owner}, state) do
    router_map =
      state.routers
      |> Map.get(router_id, %{})
      |> Map.put(request_id, %{status: :primary, log: pending_log})

    {:noreply,
     %{
       state
       | routers: Map.put(state.routers, router_id, router_map),
         owners: add_owner_entry(state.owners, owner, {router_id, request_id})
     }}
  end

  @impl true
  def handle_cast({:step_started, router_id, request_id, _step_index, step_info}, state) do
    router_map =
      state.routers
      |> Map.get(router_id, %{})
      |> Map.update(request_id, %{status: :fallback, log: nil}, fn entry ->
        %{entry | status: :fallback, log: apply_step_info(entry.log, step_info)}
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

    primary = Enum.count(requests, fn {_, entry} -> entry.status == :primary end)
    fallback = Enum.count(requests, fn {_, entry} -> entry.status == :fallback end)

    {:reply, {primary, fallback}, state}
  end

  @impl true
  def handle_call({:get_routers_counts, router_ids}, _from, state) do
    result =
      Enum.into(router_ids, %{}, fn router_id ->
        requests = Map.get(state.routers, router_id, %{})

        primary = Enum.count(requests, fn {_, entry} -> entry.status == :primary end)
        fallback = Enum.count(requests, fn {_, entry} -> entry.status == :fallback end)

        {router_id, {primary, fallback}}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_pending, router_ids}, _from, state) do
    logs =
      router_ids
      |> Enum.flat_map(fn router_id ->
        state.routers
        |> Map.get(router_id, %{})
        |> Map.values()
        |> Enum.map(& &1.log)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    {:reply, logs, state}
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
    # Hot upgrades from two legacy shapes: the bare %{router_id => %{request_id
    # => status}} map (pre-owners), and entries holding a status atom instead of
    # %{status:, log:}. Bare-map entries carry no owner pid, so they are only
    # removed by an explicit request_completed: requests in flight during the
    # upgrade still resolve normally, while entries already leaked before the
    # upgrade must be cleared manually (:sys.replace_state). Migrated entries
    # have no stored pending log; list_pending simply omits them until they
    # resolve.
    state =
      if Map.has_key?(state, :routers), do: state, else: %{routers: state, owners: %{}}

    routers =
      Map.new(state.routers, fn {router_id, requests} ->
        {router_id,
         Map.new(requests, fn
           {request_id, status} when is_atom(status) -> {request_id, %{status: status, log: nil}}
           {request_id, entry} -> {request_id, entry}
         end)}
      end)

    {:ok, %{state | routers: routers}}
  end

  defp apply_step_info(nil, _step_info), do: nil
  defp apply_step_info(log, nil), do: log
  defp apply_step_info(log, step_info), do: PendingLog.apply_fallback(log, step_info)

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
