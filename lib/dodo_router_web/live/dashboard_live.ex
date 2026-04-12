defmodule DodoRouterWeb.DashboardLive do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Routers, Logs}
  alias DodoRouter.Proxy.InflightTracker

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:routers, routers)
      |> assign(:selected_router, List.first(routers))
      |> assign(:stats, nil)
      |> assign(:stats_by_provider, [])
      |> assign(:latency_percentiles, %{})
      |> assign(:failure_breakdown, [])
      |> assign(:requests_per_minute, [])
      |> assign(:live_events, [])
      |> assign(:inflight_requests, [])

    socket =
      if socket.assigns.selected_router do
        load_stats(socket)
      else
        socket
      end

    if connected?(socket) do
      schedule_refresh()

      if socket.assigns.selected_router do
        Phoenix.PubSub.subscribe(
          DodoRouter.PubSub,
          "router:#{socket.assigns.selected_router.id}:events"
        )

        InflightTracker.subscribe(socket.assigns.selected_router.id)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"router_id" => router_id}, _url, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)

    if socket.assigns.selected_router do
      Phoenix.PubSub.unsubscribe(
        DodoRouter.PubSub,
        "router:#{socket.assigns.selected_router.id}:events"
      )

      InflightTracker.unsubscribe(socket.assigns.selected_router.id)
    end

    Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
    InflightTracker.subscribe(router.id)

    socket =
      socket
      |> assign(:selected_router, router)
      |> assign(:live_events, [])
      |> load_stats()

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_router", %{"router_id" => router_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard?router_id=#{router_id}")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    socket =
      if socket.assigns.selected_router do
        load_stats(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:proxy_event, event}, socket) do
    live_events = [event | Enum.take(socket.assigns.live_events, 19)]
    {:noreply, assign(socket, :live_events, live_events)}
  end

  def handle_info({:inflight_changed, router_id}, socket) do
    if socket.assigns.selected_router && socket.assigns.selected_router.id == router_id do
      inflight = InflightTracker.list(router_id)
      {:noreply, assign(socket, :inflight_requests, inflight)}
    else
      {:noreply, socket}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp load_stats(socket) do
    router = socket.assigns.selected_router

    socket
    |> assign(:stats, Logs.stats(router, hours: 24))
    |> assign(:stats_by_provider, Logs.stats_by_provider(router, hours: 24))
    |> assign(:latency_percentiles, Logs.latency_percentiles(router, hours: 24))
    |> assign(:failure_breakdown, Logs.failure_breakdown(router, hours: 24))
    |> assign(:requests_per_minute, Logs.requests_per_minute(router, minutes: 60))
    |> assign(:inflight_requests, InflightTracker.list(router.id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
        <div>
          <h1 class="text-2xl font-bold">Dashboard</h1>
          <p class="text-base-content/50 text-sm">Monitor your LLM proxy in real-time</p>
        </div>
        <select
          phx-change="select_router"
          name="router_id"
          class="select bg-base-200 border-base-300/50 w-full sm:w-48"
        >
          <option
            :for={r <- @routers}
            value={r.id}
            selected={@selected_router && r.id == @selected_router.id}
          >
            {r.name}
          </option>
        </select>
      </div>

      <%= if @selected_router && @stats do %>
        <!-- Stats Grid -->
        <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-6">
          <div class="stat-card">
            <div class="stat-label">Requests (24h)</div>
            <div class="stat-value">{@stats.total_requests}</div>
            <div class="stat-desc">Total API calls</div>
          </div>

          <div class="stat-card">
            <div class="stat-label">Success Rate</div>
            <div class={"stat-value #{success_color(@stats)}"}>{success_rate(@stats)}</div>
            <div class="stat-desc">{@stats.successful_requests} successful</div>
          </div>

          <div class="stat-card">
            <div class="stat-label">Fallback Rate</div>
            <div class="stat-value">{fallback_rate(@stats)}</div>
            <div class="stat-desc">{@stats.fallback_requests} fallbacks</div>
          </div>

          <div class="stat-card">
            <div class="stat-label">Tokens Used</div>
            <div class="stat-value">{format_number(@stats.total_tokens)}</div>
            <div class="stat-desc">
              {format_number(@stats.prompt_tokens)} in / {format_number(@stats.completion_tokens)} out
            </div>
          </div>

          <div class="stat-card">
            <div class="stat-label">Est. Cost</div>
            <div class="stat-value">{format_cost(@stats.total_cost_usd)}</div>
            <div class="stat-desc">Last 24 hours</div>
          </div>
        </div>
        
    <!-- Latency Stats -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
          <div class="stat-card flex items-center gap-4">
            <div class="stat-icon">
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
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <div>
              <div class="stat-label">p50 Latency</div>
              <div class="stat-value">{format_latency(@latency_percentiles.p50)}</div>
              <div class="stat-desc">Median response time</div>
            </div>
          </div>

          <div class="stat-card flex items-center gap-4">
            <div class="stat-icon">
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
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <div>
              <div class="stat-label">p95 Latency</div>
              <div class="stat-value">{format_latency(@latency_percentiles.p95)}</div>
              <div class="stat-desc">95th percentile</div>
            </div>
          </div>

          <div class="stat-card flex items-center gap-4">
            <div class="stat-icon">
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
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <div>
              <div class="stat-label">p99 Latency</div>
              <div class="stat-value">{format_latency(@latency_percentiles.p99)}</div>
              <div class="stat-desc">99th percentile</div>
            </div>
          </div>
        </div>
        
    <!-- Charts Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
          <!-- Requests per Minute -->
          <div class="chart-container">
            <h2 class="section-title">Requests per Minute</h2>
            <p class="section-desc mb-4">Last 60 minutes</p>
            <div class="h-32 flex items-end gap-0.5">
              <%= for bucket <- pad_rpm(@requests_per_minute, 60) do %>
                <div
                  class="flex-1 bg-primary/60 hover:bg-primary rounded-t transition-all"
                  style={"height: #{bucket_height(bucket, @requests_per_minute)}%"}
                  title={"#{bucket.count} requests"}
                >
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Provider Breakdown -->
          <div class="chart-container">
            <h2 class="section-title">By Provider</h2>
            <p class="section-desc mb-4">Request distribution (24h)</p>
            <div class="space-y-3">
              <%= for stat <- @stats_by_provider do %>
                <div class="flex items-center gap-4">
                  <span class="w-24 text-sm text-base-content/80">{stat.provider}</span>
                  <div class="flex-1 h-2 bg-base-200 rounded-full overflow-hidden">
                    <div
                      class="h-full bg-primary/70 rounded-full"
                      style={"width: #{if @stats.total_requests > 0, do: round(stat.total_requests / @stats.total_requests * 100), else: 0}%"}
                    >
                    </div>
                  </div>
                  <span class="w-12 text-right text-sm font-mono text-base-content/70">
                    {stat.total_requests}
                  </span>
                </div>
              <% end %>
              <p :if={Enum.empty?(@stats_by_provider)} class="empty-state text-sm py-4">
                No data yet
              </p>
            </div>
          </div>
        </div>
        
    <!-- Failures & Live Events -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <!-- Failures -->
          <div :if={length(@failure_breakdown) > 0} class="table-container">
            <div class="p-5">
              <h2 class="section-title">Failures (24h)</h2>
            </div>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Provider</th>
                  <th>Model</th>
                  <th>Status</th>
                  <th class="text-right">Count</th>
                </tr>
              </thead>
              <tbody>
                <%= for f <- @failure_breakdown do %>
                  <tr class="hover:bg-base-200/30">
                    <td class="text-base-content/80">{f.provider}</td>
                    <td class="font-mono text-xs text-base-content/70">{f.model}</td>
                    <td>
                      <span class={"px-2 py-0.5 rounded text-xs font-medium #{if f.status == "error", do: "bg-error/20 text-error", else: "bg-warning/20 text-warning"}"}>
                        {f.status}
                      </span>
                    </td>
                    <td class="font-mono text-right text-base-content/70">{f.count}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
          
    <!-- In-Flight Requests -->
          <div :if={length(@inflight_requests) > 0} class="chart-container mb-4 lg:col-span-2">
            <div class="flex items-center gap-3 mb-4">
              <h2 class="section-title mb-0">In-Flight</h2>
              <span class="flex items-center gap-1.5 px-2 py-0.5 bg-info/10 rounded text-xs font-medium text-info">
                <span class="live-dot bg-info"></span>
                {length(@inflight_requests)} active
              </span>
            </div>
            <div class="space-y-2">
              <%= for req <- @inflight_requests do %>
                <div class="flex items-center justify-between p-3 rounded-lg text-sm bg-info/5 border border-info/20">
                  <div class="flex items-center gap-3">
                    <span class="relative flex h-2 w-2">
                      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-info opacity-75">
                      </span>
                      <span class="relative inline-flex rounded-full h-2 w-2 bg-info"></span>
                    </span>
                    <span class="font-mono text-base-content/80">
                      {req.provider}/{req.model}
                    </span>
                    <span
                      :if={req.streaming}
                      class="px-1.5 py-0.5 bg-primary/20 text-primary rounded text-xs"
                    >
                      streaming
                    </span>
                  </div>
                  <div class="flex items-center gap-4 text-base-content/50 text-sm">
                    <span class="font-mono">{format_elapsed(req.elapsed_ms)}</span>
                    <span class="text-xs">{format_event_time(req.started_at)}</span>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

    <!-- Live Events -->
          <div class="chart-container">
            <div class="flex items-center gap-3 mb-4">
              <h2 class="section-title mb-0">Live Events</h2>
              <span class="flex items-center gap-1.5 px-2 py-0.5 bg-success/10 rounded text-xs font-medium text-success">
                <span class="live-dot"></span> Live
              </span>
            </div>
            <div class="space-y-2 max-h-64 overflow-y-auto">
              <%= for event <- @live_events do %>
                <div class={"flex items-center justify-between p-3 rounded-lg text-sm #{event_class(event)}"}>
                  <div class="flex items-center gap-3">
                    <span class={"w-2 h-2 rounded-full #{event_dot_class(event)}"}></span>
                    <span class="font-mono text-base-content/80">{event.provider}/{event.model}</span>
                    <span
                      :if={event.had_fallback}
                      class="px-1.5 py-0.5 bg-warning/20 text-warning rounded text-xs"
                    >
                      fallback
                    </span>
                  </div>
                  <div class="flex items-center gap-4 text-base-content/50 text-sm">
                    <span class="font-mono">{event.latency_ms}ms</span>
                    <span>{format_event_time(event.timestamp)}</span>
                  </div>
                </div>
              <% end %>
              <p :if={Enum.empty?(@live_events)} class="empty-state py-8">
                Waiting for requests...
              </p>
            </div>
          </div>
        </div>
      <% else %>
        <!-- Empty State -->
        <div class="card-bordered p-12 text-center">
          <div class="max-w-md mx-auto">
            <div class="stat-icon w-16 h-16 mx-auto mb-6">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-8 w-8"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
            </div>
            <h2 class="text-xl font-semibold mb-2">Welcome to DodoRouter</h2>
            <p class="text-base-content/50 mb-6">
              Create your first router to start routing LLM requests with automatic fallbacks.
            </p>
            <a href={~p"/routers/new"} class="btn btn-primary">Create Router</a>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp success_rate(%{total_requests: 0}), do: "-"

  defp success_rate(%{total_requests: total, successful_requests: success}) do
    "#{round(success / total * 100)}%"
  end

  defp success_color(%{total_requests: 0}), do: ""

  defp success_color(%{total_requests: total, successful_requests: success}) do
    rate = success / total * 100

    cond do
      rate >= 95 -> ""
      rate >= 80 -> "text-warning"
      true -> "text-error"
    end
  end

  defp fallback_rate(%{total_requests: 0}), do: "-"

  defp fallback_rate(%{total_requests: total, fallback_requests: fallback}) do
    "#{round(fallback / total * 100)}%"
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_latency(nil), do: "-"
  defp format_latency(ms), do: "#{round(ms)}ms"

  defp format_cost(nil), do: "$0.00"
  defp format_cost(cost), do: "$#{Decimal.round(cost, 2)}"

  defp format_event_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_elapsed(ms) when ms < 1000, do: "#{ms}ms"
  defp format_elapsed(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp event_class(%{status: :success}), do: "bg-success/10"
  defp event_class(%{status: :fallback}), do: "bg-warning/10"
  defp event_class(_), do: "bg-error/10"

  defp event_dot_class(%{status: :success}), do: "bg-success"
  defp event_dot_class(%{status: :fallback}), do: "bg-warning"
  defp event_dot_class(_), do: "bg-error"

  defp pad_rpm(buckets, target_count) do
    existing = length(buckets)
    padding = max(0, target_count - existing)
    List.duplicate(%{count: 0}, padding) ++ buckets
  end

  defp bucket_height(_bucket, []), do: 0
  defp bucket_height(%{count: 0}, _all), do: 2

  defp bucket_height(%{count: count}, all) do
    max_count = Enum.map(all, & &1.count) |> Enum.max(fn -> 1 end)
    max(2, round(count / max_count * 100))
  end
end
