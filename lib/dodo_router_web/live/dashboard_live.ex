defmodule DodoRouterWeb.DashboardLive do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Routers, Logs}

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

    socket =
      if socket.assigns.selected_router do
        load_stats(socket)
      else
        socket
      end

    if connected?(socket) do
      schedule_refresh()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"router_id" => router_id}, _url, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)

    socket =
      socket
      |> assign(:selected_router, router)
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

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp load_stats(socket) do
    router = socket.assigns.selected_router

    socket
    |> assign(:stats, Logs.stats(router, hours: 24))
    |> assign(:stats_by_provider, Logs.stats_by_provider(router, hours: 24))
    |> assign(:stats_by_model, Logs.stats_by_model(router, hours: 24))
    |> assign(:latency_percentiles, Logs.latency_percentiles(router, hours: 24))
    |> assign(:failure_breakdown, Logs.failure_breakdown(router, hours: 24))
    |> assign(:requests_per_minute, Logs.requests_per_minute(router, minutes: 60))
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
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-6">
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
        </div>
        
    <!-- Latency Stats -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-6">
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
        
    <!-- Model Leaderboard -->
        <div :if={length(@stats_by_model) > 0} class="card-bordered mb-6">
          <h2 class="section-title">Model Leaderboard</h2>
          <p class="section-desc mb-4">Performance ranking (24h)</p>
          <div class="space-y-2">
            <%= for {stat, idx} <- @stats_by_model |> rank_by_success_rate() |> Enum.with_index() do %>
              <div class={[
                "flex items-center gap-4 p-3 rounded-lg",
                success_rate_value(stat) >= 95 && "bg-success/10",
                success_rate_value(stat) >= 80 && success_rate_value(stat) < 95 && "bg-warning/10",
                success_rate_value(stat) < 80 && "bg-error/10"
              ]}>
                <span class={[
                  "w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold",
                  idx == 0 && "bg-yellow-500/20 text-yellow-600",
                  idx == 1 && "bg-gray-300/30 text-gray-500",
                  idx == 2 && "bg-amber-600/20 text-amber-700",
                  idx > 2 && "bg-base-200 text-base-content/50"
                ]}>
                  {idx + 1}
                </span>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="font-medium text-base-content/90">{stat.provider}</span>
                    <span class="text-base-content/40">/</span>
                    <span class="font-mono text-sm text-base-content/70 truncate">{stat.model}</span>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">
                    {stat.total_requests} requests · {format_latency(stat.avg_latency_ms)} avg
                  </div>
                </div>
                <div class="text-right">
                  <div class={[
                    "text-lg font-bold",
                    success_rate_value(stat) >= 95 && "text-success",
                    success_rate_value(stat) >= 80 && success_rate_value(stat) < 95 && "text-warning",
                    success_rate_value(stat) < 80 && "text-error"
                  ]}>
                    {success_rate(stat)}
                  </div>
                  <div class="text-xs text-base-content/50">success rate</div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Charts Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-3 mb-6">
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
        </div>
      <% else %>
        <!-- Empty State -->
        <div class="card-bordered text-center">
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

  defp success_rate_value(%{total_requests: 0}), do: 0

  defp success_rate_value(%{total_requests: total, successful_requests: success}) do
    success / total * 100
  end

  defp rank_by_success_rate(stats) do
    Enum.sort_by(stats, &success_rate_value/1, :desc)
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_latency(nil), do: "-"
  defp format_latency(%Decimal{} = ms), do: "#{ms |> Decimal.round(0) |> Decimal.to_integer()}ms"
  defp format_latency(ms), do: "#{round(ms)}ms"

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
