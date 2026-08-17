defmodule DodoRouterWeb.RecordingLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Recordings
  alias DodoRouter.Routers

  @impl true
  def mount(%{"router_id" => router_id, "id" => id}, _session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)
    recording = Recordings.get_recording!(id)

    if recording.router_id != router.id do
      {:ok, redirect(socket, to: ~p"/routers/#{router.id}/recordings")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:logs")
      end

      socket =
        socket
        |> assign(:router, router)
        |> assign(:recording, recording)
        |> assign(:page_title, "Recording — #{recording.name || recording.id}")
        |> load_data()

      {:ok, socket}
    end
  end

  def mount(_params, _socket_session, socket) do
    {:ok, redirect(socket, to: ~p"/routers")}
  end

  @impl true
  def handle_info({:log_created, log}, socket) do
    if log.recording_id == socket.assigns.recording.id do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <div class="flex items-center gap-3 mb-6">
          <a
            href={~p"/routers/#{@router.id}/recordings"}
            class="p-2 rounded-lg hover:bg-base-200 transition-colors text-base-content/60"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
          </a>
          <div class="flex-1">
            <div class="flex items-center gap-2">
              <h1 class="text-xl font-bold">
                {if @recording.name, do: @recording.name, else: "Recording"}
              </h1>
              <span class={[
                "px-2 py-0.5 rounded text-xs font-medium",
                if(@recording.status == "recording",
                  do: "bg-success/20 text-success",
                  else: "bg-base-300/50 text-base-content/50"
                )
              ]}>
                {@recording.status}
              </span>
              <div class="ml-auto">
                <.link
                  :if={@stats.request_count > 0}
                  id="benchmark-recording-button"
                  navigate={~p"/routers/#{@router.id}/recordings/#{@recording.id}/evals/new"}
                  class="btn btn-primary btn-sm gap-2"
                >
                  <.icon name="hero-scale" class="size-4" /> Benchmark this recording
                </.link>
              </div>
            </div>
            <p class="text-sm text-base-content/50 mt-0.5">
              {Calendar.strftime(@recording.started_at, "%b %d, %H:%M:%S")}
              <%= if @recording.stopped_at do %>
                <span class="mx-1">→</span>
                {Calendar.strftime(@recording.stopped_at, "%b %d, %H:%M:%S")}
                <span class="ml-2 text-base-content/40">
                  ({format_duration(@recording.started_at, @recording.stopped_at)})
                </span>
              <% end %>
            </p>
          </div>
        </div>
        
    <!-- Stats -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
            <div class="stat-title text-xs">Requests</div>
            <div class="stat-value text-lg">{@stats.request_count}</div>
          </div>
          <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
            <div class="stat-title text-xs">Total Tokens</div>
            <div class="stat-value text-lg">{@stats.total_tokens || 0}</div>
          </div>
          <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
            <div class="stat-title text-xs">p95 Latency</div>
            <div class="stat-value text-lg">{format_latency(@latency_percentiles.p95)}ms</div>
            <div class="text-xs text-base-content/50 mt-0.5">
              p50 {format_latency(@latency_percentiles.p50)}ms
            </div>
          </div>
          <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
            <div class="stat-title text-xs">Success Rate</div>
            <div class="stat-value text-lg">
              <%= if @stats.request_count > 0 do %>
                {round((@stats.successful_requests || 0) / @stats.request_count * 100)}%
              <% else %>
                —
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Benchmarks measured on this capture -->
        <div :if={@evaluations != []} id="recording-benchmarks" class="mb-6">
          <h2 class="text-lg font-semibold mb-3">Benchmarks on this recording</h2>
          <div class="space-y-2">
            <.link
              :for={evaluation <- @evaluations}
              navigate={~p"/evals/#{evaluation.id}"}
              class="block bg-base-100 border border-base-300 rounded-lg p-3 hover:border-primary transition-colors"
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <.icon name="hero-scale" class="size-4 text-primary" />
                  <span class="text-sm font-medium">{evaluation.name}</span>
                  <span class="badge badge-sm badge-ghost">{evaluation.benchmark_status}</span>
                </div>
                <div class="text-xs text-base-content/50">
                  {evaluation.run_count} runs
                  · {Calendar.strftime(evaluation.inserted_at, "%b %d, %H:%M")}
                </div>
              </div>
            </.link>
          </div>
        </div>
        
    <!-- Request timeline -->
        <h2 class="text-lg font-semibold mb-3">Captured Requests</h2>
        <div class="space-y-2">
          <%= for log <- @logs do %>
            <a
              href={
              ~p"/logs/#{log.id}" <>
                "?return_to=" <>
                URI.encode_www_form("/routers/#{@router.id}/recordings/#{@recording.id}")
            }
              class="block bg-base-100 border border-base-300 rounded-lg p-3 hover:border-primary transition-colors"
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <span class={[
                    "badge badge-sm",
                    if(log.status in ["success", "fallback"],
                      do: "badge-success",
                      else: "badge-error"
                    )
                  ]}>
                    {log.status}
                  </span>
                  <span class="text-sm font-medium">{log.final_model || "unknown"}</span>
                </div>
                <div class="text-xs text-base-content/50">
                  {log.latency_ms}ms · {log.total_tokens || 0} tokens
                  · {Calendar.strftime(log.inserted_at, "%H:%M:%S")}
                </div>
              </div>
            </a>
          <% end %>

          <%= if Enum.empty?(@logs) do %>
            <div class="text-center py-8 text-base-content/50">
              No requests captured yet.
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_data(socket) do
    recording = socket.assigns.recording

    stats = Recordings.recording_stats(recording)
    logs = Recordings.list_logs_for_recording(recording, limit: 100)

    socket
    |> assign(:stats, stats)
    |> assign(:logs, logs)
    |> assign(
      :evaluations,
      Evaluations.list_for_recording(socket.assigns.current_user, recording.id)
    )
    |> assign(:latency_percentiles, latency_percentiles(logs))
  end

  # A recording is bounded like a session — the logs are already loaded for
  # the timeline, so percentiles are computed from those in memory rather
  # than a separate DB aggregate (nearest-rank method).
  defp latency_percentiles(logs) do
    latencies =
      logs
      |> Enum.map(&Map.get(&1, :latency_ms))
      |> Enum.filter(&is_number/1)
      |> Enum.sort()

    %{p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95)}
  end

  defp percentile([], _p), do: nil

  defp percentile(sorted, p) do
    count = length(sorted)
    index = max(0, ceil(p * count) - 1)
    Enum.at(sorted, index)
  end

  defp format_latency(nil), do: "0"
  defp format_latency(%Decimal{} = ms), do: ms |> Decimal.round(0) |> Decimal.to_integer()
  defp format_latency(ms), do: round(ms)

  defp format_duration(started, stopped) do
    diff = DateTime.diff(stopped, started, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end
end
