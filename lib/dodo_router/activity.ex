defmodule DodoRouter.Activity do
  @moduledoc """
  Tracks in-flight requests per router for real-time activity display.

  Simple Agent that maintains state of active requests. No persistence,
  no TTL - requests are explicitly added and removed via event handlers.
  State is keyed by router_id since router IDs are globally unique.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Track a new request as active on primary provider.
  """
  def request_started(router_id, request_id) do
    Agent.update(__MODULE__, fn state ->
      router_map = Map.get(state, router_id, %{})
      new_router_map = Map.put(router_map, request_id, :primary)
      Map.put(state, router_id, new_router_map)
    end)
  end

  @doc """
  Transition a request from primary to fallback status.
  """
  def step_started(router_id, request_id, step_index) when step_index > 0 do
    Agent.update(__MODULE__, fn state ->
      router_map = Map.get(state, router_id, %{})

      new_router_map =
        Map.update(router_map, request_id, :fallback, fn
          :primary -> :fallback
          status -> status
        end)

      Map.put(state, router_id, new_router_map)
    end)
  end

  @doc """
  Remove a completed request from tracking.
  """
  def request_completed(router_id, request_id) do
    Agent.update(__MODULE__, fn state ->
      router_map = Map.get(state, router_id, %{})
      {_, new_router_map} = Map.pop(router_map, request_id)

      if map_size(new_router_map) == 0 do
        Map.delete(state, router_id)
      else
        Map.put(state, router_id, new_router_map)
      end
    end)
  end

  @doc """
  Get activity counts for a specific router.
  Returns {primary_count, fallback_count}.
  """
  def get_router_counts(router_id) do
    Agent.get(__MODULE__, fn state ->
      requests = Map.get(state, router_id, %{})

      primary =
        requests
        |> Enum.filter(fn {_, status} -> status == :primary end)
        |> Enum.count()

      fallback =
        requests
        |> Enum.filter(fn {_, status} -> status == :fallback end)
        |> Enum.count()

      {primary, fallback}
    end)
  end

  @doc """
  Get activity counts for multiple routers at once.
  Returns %{router_id => {primary_count, fallback_count}}.
  """
  def get_routers_counts(router_ids) do
    Agent.get(__MODULE__, fn state ->
      Enum.into(router_ids, %{}, fn router_id ->
        requests = Map.get(state, router_id, %{})

        primary = Enum.count(requests, fn {_, status} -> status == :primary end)
        fallback = Enum.count(requests, fn {_, status} -> status == :fallback end)

        {router_id, {primary, fallback}}
      end)
    end)
  end

  @doc """
  Get total active request count across given routers.
  """
  def get_total_active(router_ids) do
    Agent.get(__MODULE__, fn state ->
      Enum.reduce(router_ids, 0, fn router_id, acc ->
        requests = Map.get(state, router_id, %{})
        acc + map_size(requests)
      end)
    end)
  end
end
