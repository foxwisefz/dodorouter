defmodule DodoRouter.Proxy.FinchTelemetry do
  @moduledoc """
  Telemetry handler for Finch HTTP events.

  Captures send/recv timing to enable fair model comparisons by separating
  upload time from server processing time.

  Uses ETS with time-window correlation since Finch telemetry events fire
  in pool worker processes, not the caller's process.
  """

  require Logger

  @table __MODULE__
  @ttl_ms 60_000

  @doc """
  Attaches telemetry handlers and creates ETS table. Call during application startup.
  """
  def attach do
    # Create ETS table if it doesn't exist (safe for hot reloads)
    try do
      :ets.new(@table, [:ordered_set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    events = [
      [:finch, :send, :stop],
      [:finch, :recv, :stop]
    ]

    # Detach first to allow re-attaching on hot reload
    :telemetry.detach("dodo-router-finch-telemetry")

    :telemetry.attach_many(
      "dodo-router-finch-telemetry",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:finch, :send, :stop], measurements, _metadata, _config) do
    duration_native = measurements[:duration] || 0
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)
    stop_time = System.monotonic_time(:millisecond)

    # Store with stop_time as key for time-window lookup
    :ets.insert(@table, {{:send, stop_time}, duration_ms})

    # Cleanup old entries periodically (1 in 100 chance)
    if :rand.uniform(100) == 1, do: cleanup_old_entries(stop_time)
  end

  def handle_event([:finch, :recv, :stop], _measurements, metadata, _config) do
    headers = metadata[:headers] || []
    recv_time = System.monotonic_time(:millisecond)
    :ets.insert(@table, {{:headers, recv_time}, headers})
  end

  defp cleanup_old_entries(now) do
    cutoff = now - @ttl_ms
    # Delete send entries older than TTL
    :ets.select_delete(@table, [
      {{{:send, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]},
      {{{:headers, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  @doc """
  Marks the start of a request. Call right before Req.post().
  Returns the start_time to pass to get_upload_ms/1 later.
  """
  def mark_request_start do
    System.monotonic_time(:millisecond)
  end

  @doc """
  Gets the upload duration by finding send:stop events in the time window.
  Pass the start_time from mark_request_start/0.
  """
  def get_upload_ms(start_time) do
    now = System.monotonic_time(:millisecond)

    # Find send events where stop_time is between start_time and now
    # Use select to find entries in the time range
    result =
      :ets.select(@table, [
        {{{:send, :"$1"}, :"$2"}, [{:>=, :"$1", start_time}, {:"=<", :"$1", now}],
         [{{:"$1", :"$2"}}]}
      ])


    case result do
      [] ->
        nil

      [{_stop_time, duration_ms}] ->
        duration_ms

      multiple ->
        # Multiple matches - pick the one closest to start_time (most likely ours)
        {_stop_time, duration_ms} =
          Enum.min_by(multiple, fn {stop_time, _} -> stop_time - start_time end)

        duration_ms
    end
  end

  @doc """
  Gets response headers by finding recv:stop events in the time window.
  """
  def get_response_headers(start_time) do
    now = System.monotonic_time(:millisecond)

    case :ets.select(@table, [
           {{{:headers, :"$1"}, :"$2"}, [{:>=, :"$1", start_time}, {:"=<", :"$1", now}],
            [{{:"$1", :"$2"}}]}
         ]) do
      [] ->
        []

      [{_recv_time, headers}] ->
        headers

      multiple ->
        # Multiple matches - pick the most recent one
        {_recv_time, headers} = Enum.max_by(multiple, fn {recv_time, _} -> recv_time end)
        headers
    end
  end

  @doc """
  Clears is now a no-op since we use time-window correlation.
  Kept for API compatibility.
  """
  def clear, do: :ok

  @doc """
  Extracts provider processing time from response headers.
  Currently supports OpenAI's `openai-processing-ms` header.
  Handles both list format (from Finch) and map format (from Req).
  """
  def extract_provider_processing_ms(headers) when is_list(headers) do
    case List.keyfind(headers, "openai-processing-ms", 0) do
      {_, value} -> parse_int(value)
      nil -> nil
    end
  end

  def extract_provider_processing_ms(headers) when is_map(headers) do
    case Map.get(headers, "openai-processing-ms") do
      [value | _] -> parse_int(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  def extract_provider_processing_ms(_), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil
end
