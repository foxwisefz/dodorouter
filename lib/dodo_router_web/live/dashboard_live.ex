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
      |> assign(:live_events, [])

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
    end

    Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")

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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <h1 class="text-2xl font-bold">Dashboard</h1>
          <p class="text-base-content/60">Monitor your LLM proxy in real-time</p>
        </div>
        <select
          phx-change="select_router"
          name="router_id"
          class="select select-bordered w-full sm:w-auto"
        >
          <option :for={r <- @routers} value={r.id} selected={@selected_router && r.id == @selected_router.id}>
            <%= r.name %>
          </option>
        </select>
      </div>

      <%= if @selected_router && @stats do %>
        <!-- Stats Grid -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4 mb-6">
          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-title">Requests (24h)</div>
            <div class="stat-value text-primary"><%= @stats.total_requests %></div>
            <div class="stat-desc">Total API calls</div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-title">Success Rate</div>
            <div class={"stat-value #{success_color(@stats)}"}><%= success_rate(@stats) %></div>
            <div class="stat-desc"><%= @stats.successful_requests %> successful</div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-title">Fallback Rate</div>
            <div class="stat-value text-warning"><%= fallback_rate(@stats) %></div>
            <div class="stat-desc"><%= @stats.fallback_requests %> fallbacks</div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-title">Tokens Used</div>
            <div class="stat-value"><%= format_number(@stats.total_tokens) %></div>
            <div class="stat-desc">
              <span class="text-info"><%= format_number(@stats.prompt_tokens) %></span> in /
              <span class="text-success"><%= format_number(@stats.completion_tokens) %></span> out
            </div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-title">Est. Cost</div>
            <div class="stat-value"><%= format_cost(@stats.total_cost_usd) %></div>
            <div class="stat-desc">Last 24 hours</div>
          </div>
        </div>

        <!-- Latency Stats -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-figure text-info">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div class="stat-title">p50 Latency</div>
            <div class="stat-value text-info"><%= format_latency(@latency_percentiles.p50) %></div>
            <div class="stat-desc">Median response time</div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-figure text-warning">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div class="stat-title">p95 Latency</div>
            <div class="stat-value text-warning"><%= format_latency(@latency_percentiles.p95) %></div>
            <div class="stat-desc">95th percentile</div>
          </div>

          <div class="stat bg-base-100 rounded-box shadow">
            <div class="stat-figure text-error">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
            <div class="stat-title">p99 Latency</div>
            <div class="stat-value text-error"><%= format_latency(@latency_percentiles.p99) %></div>
            <div class="stat-desc">99th percentile</div>
          </div>
        </div>

        <!-- Charts Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
          <!-- Requests per Minute -->
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Requests per Minute</h2>
              <p class="text-sm text-base-content/60">Last 60 minutes</p>
              <div class="h-32 flex items-end gap-0.5 mt-4">
                <%= for bucket <- pad_rpm(@requests_per_minute, 60) do %>
                  <div
                    class="flex-1 bg-primary rounded-t transition-all hover:bg-primary-focus"
                    style={"height: #{bucket_height(bucket, @requests_per_minute)}%"}
                    title={"#{bucket.count} requests"}
                  >
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Provider Breakdown -->
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">By Provider</h2>
              <p class="text-sm text-base-content/60">Request distribution (24h)</p>
              <div class="space-y-3 mt-4">
                <%= for stat <- @stats_by_provider do %>
                  <div class="flex items-center gap-4">
                    <span class="w-20 font-medium text-sm"><%= stat.provider %></span>
                    <div class="flex-1">
                      <progress
                        class="progress progress-primary w-full"
                        value={stat.total_requests}
                        max={@stats.total_requests}
                      ></progress>
                    </div>
                    <span class="w-12 text-right text-sm font-mono"><%= stat.total_requests %></span>
                  </div>
                <% end %>
                <p :if={Enum.empty?(@stats_by_provider)} class="text-base-content/50 text-sm">No data yet</p>
              </div>
            </div>
          </div>
        </div>

        <!-- Failures & Live Events -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Failures -->
          <div :if={length(@failure_breakdown) > 0} class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-base">Failures (24h)</h2>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Provider</th>
                      <th>Model</th>
                      <th>Status</th>
                      <th>Count</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for f <- @failure_breakdown do %>
                      <tr>
                        <td><%= f.provider %></td>
                        <td class="font-mono text-xs"><%= f.model %></td>
                        <td>
                          <span class={"badge badge-sm #{if f.status == "error", do: "badge-error", else: "badge-warning"}"}>
                            <%= f.status %>
                          </span>
                        </td>
                        <td class="font-mono"><%= f.count %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <!-- Live Events -->
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <div class="flex items-center gap-2">
                <h2 class="card-title text-base">Live Events</h2>
                <span class="badge badge-success badge-sm gap-1">
                  <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
                  Live
                </span>
              </div>
              <div class="space-y-2 mt-4 max-h-64 overflow-y-auto">
                <%= for event <- @live_events do %>
                  <div class={"flex items-center justify-between p-2 rounded text-sm #{event_class(event)}"}>
                    <div class="flex items-center gap-2">
                      <span class={"w-2 h-2 rounded-full #{event_dot_class(event)}"}></span>
                      <span class="font-mono"><%= event.provider %>/<%= event.model %></span>
                      <span :if={event.had_fallback} class="badge badge-warning badge-xs">fallback</span>
                    </div>
                    <div class="flex items-center gap-4 text-base-content/60">
                      <span><%= event.latency_ms %>ms</span>
                      <span class="text-xs"><%= format_event_time(event.timestamp) %></span>
                    </div>
                  </div>
                <% end %>
                <p :if={Enum.empty?(@live_events)} class="text-base-content/50 text-sm text-center py-8">
                  Waiting for requests...
                </p>
              </div>
            </div>
          </div>
        </div>
      <% else %>
        <!-- Empty State -->
        <div class="hero min-h-[400px] bg-base-100 rounded-box">
          <div class="hero-content text-center">
            <div class="max-w-md">
              <h1 class="text-3xl font-bold">Welcome to DodoRouter</h1>
              <p class="py-6 text-base-content/60">
                Create your first router to start routing LLM requests with automatic fallbacks.
              </p>
              <a href={~p"/routers/new"} class="btn btn-primary">Create Router</a>
            </div>
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
      rate >= 99 -> "text-success"
      rate >= 95 -> "text-warning"
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
