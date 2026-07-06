defmodule DodoRouterWeb.DashboardLive do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Routers, Logs}
  alias DodoRouter.Proxy.Adapter.Registry

  @refresh_interval_ms 5_000
  @router_colors ~w(blue purple amber rose emerald sky orange indigo)

  @impl true
  def mount(params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    selected_router = find_selected_router(routers, params["router_id"])

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:routers, routers)
      |> assign(:selected_router, selected_router)
      |> assign(:stats, nil)
      |> assign(:stats_by_provider, [])
      |> assign(:latency_percentiles, %{})
      |> assign(:failure_breakdown, [])
      |> assign(:requests_per_minute, [])
      |> assign(:cache_stats, nil)
      |> assign(:selected_router_steps, [])
      |> assign(:recent_logs, [])
      |> assign(:loading, false)

    socket =
      if selected_router do
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
    router = find_selected_router(socket.assigns.routers, router_id)

    socket =
      socket
      |> assign(:selected_router, router)
      |> assign(:loading, true)
      |> load_stats()
      |> assign(:loading, false)

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket) do
    socket =
      if socket.assigns.selected_router do
        load_stats(socket)
      else
        socket
      end

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

  defp find_selected_router(routers, router_id) when is_binary(router_id) do
    Enum.find(routers, &(&1.id == router_id)) || List.first(routers)
  end

  defp find_selected_router(routers, _router_id) do
    List.first(routers)
  end

  defp load_stats(socket) do
    router = socket.assigns.selected_router

    socket
    |> assign(:stats, Logs.stats(router, hours: 24))
    |> assign(:stats_by_provider, Logs.stats_by_provider(router, hours: 24))
    |> assign(:latency_percentiles, Logs.latency_percentiles(router, hours: 24))
    |> assign(:failure_breakdown, Logs.failure_breakdown(router, hours: 24))
    |> assign(:requests_per_minute, Logs.requests_per_minute(router, minutes: 60))
    |> assign(:cache_stats, Logs.cache_stats(router, hours: 24))
    |> assign(:selected_router_steps, Routers.list_routing_steps(router))
    |> assign(:recent_logs, Logs.list_logs(router, limit: 8))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-6">
        <div class="flex items-center gap-3 mb-1">
          <h1 class="text-lg font-semibold text-base-content">Router Overview</h1>
          <div
            :if={@selected_router}
            class="flex items-center gap-1.5 rounded-full bg-green-50 px-2.5 py-0.5"
          >
            <span class="h-1.5 w-1.5 rounded-full bg-success"></span>
            <span class="text-xs font-semibold text-success">Live</span>
          </div>
        </div>
        <p :if={@selected_router} class="text-sm text-base-content/50">
          {@selected_router.name}
        </p>
      </div>

      <%= if length(@routers) > 0 do %>
        <div class="flex items-center gap-2 mb-6 overflow-x-auto pb-1">
          <%= for {router, idx} <- Enum.with_index(@routers) do %>
            <% color = router_color(idx) %>
            <button
              phx-click="select_router"
              phx-value-router_id={router.id}
              class={[
                "flex items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-all duration-150 shrink-0",
                @selected_router && router.id == @selected_router.id &&
                  "bg-accent text-accent-content shadow-sm",
                (!@selected_router || router.id != @selected_router.id) &&
                  "bg-base-100 border border-base-300/50 text-base-content/70 hover:bg-secondary hover:border-base-300"
              ]}
            >
              <span class={[
                "flex h-5 w-5 items-center justify-center rounded text-xs font-bold shrink-0",
                color == "blue" && "bg-blue-100 text-blue-700",
                color == "purple" && "bg-purple-100 text-purple-700",
                color == "amber" && "bg-amber-100 text-amber-700",
                color == "rose" && "bg-rose-100 text-rose-700",
                color == "emerald" && "bg-emerald-100 text-emerald-700",
                color == "sky" && "bg-sky-100 text-sky-700",
                color == "orange" && "bg-orange-100 text-orange-700",
                color == "indigo" && "bg-indigo-100 text-indigo-700"
              ]}>
                {String.upcase(String.first(router.name))}
              </span>
              <span class="truncate max-w-[120px]">{router.name}</span>
            </button>
          <% end %>
        </div>
      <% end %>

      <%= if @selected_router && @stats do %>
        <div class={[
          "transition-opacity duration-200",
          @loading && "opacity-50"
        ]}>
          <div class="grid grid-cols-2 lg:grid-cols-5 gap-3 mb-4">
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <p class="text-xs font-medium text-base-content/50">Total Requests</p>
              <p class="mt-0.5 text-lg font-semibold text-base-content">
                {format_number(@stats.total_requests)}
              </p>
              <p class="mt-0.5 text-xs text-base-content/40">Last 24 hours</p>
            </div>
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <p class="text-xs font-medium text-base-content/50">Success Rate</p>
              <p class={["mt-0.5 text-lg font-semibold", success_color(@stats)]}>
                {success_rate(@stats)}
              </p>
              <p class="mt-0.5 text-xs text-base-content/40">
                {if @stats.fallback_requests > 0,
                  do: "#{@stats.fallback_requests} fallbacks recovered",
                  else: "All requests successful"}
              </p>
            </div>
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <p class="text-xs font-medium text-base-content/50">p95 Latency</p>
              <p class="mt-0.5 text-lg font-semibold text-base-content">
                {format_latency(@latency_percentiles.p95)}
              </p>
              <p class="mt-0.5 text-xs text-base-content/40">95th percentile</p>
            </div>
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <p class="text-xs font-medium text-base-content/50">Total Tokens</p>
              <p class="mt-0.5 text-lg font-semibold text-base-content">
                {format_number(@stats.total_tokens)}
              </p>
              <p class="mt-0.5 text-xs text-base-content/40">
                {format_number(@stats.prompt_tokens)} in / {format_number(@stats.completion_tokens)} out
              </p>
            </div>
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <p class="text-xs font-medium text-base-content/50">Cache Hit Rate</p>
              <p class="mt-0.5 text-lg font-semibold text-base-content">
                {if @cache_stats && @cache_stats.hit_rate > 0,
                  do: "#{@cache_stats.hit_rate}%",
                  else: "-"}
              </p>
              <p class="mt-0.5 text-xs text-base-content/40">
                {if @cache_stats && @cache_stats.cached_requests > 0,
                  do:
                    "#{format_number(@cache_stats.cached_requests)}/#{format_number(@cache_stats.total_requests)} requests",
                  else: "No cache data"}
              </p>
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-3 mb-4">
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <div class="flex items-center justify-between mb-2">
                <p class="text-sm font-semibold text-base-content">Request Volume</p>
                <p class="text-xs text-base-content/40">Last 60 min</p>
              </div>
              <div class="h-20">
                <svg viewBox="0 0 200 60" class="h-full w-full" preserveAspectRatio="none">
                  <defs>
                    <linearGradient id="chartFill" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color="hsl(239, 84%, 67%)" stop-opacity="0.15" />
                      <stop offset="100%" stop-color="hsl(239, 84%, 67%)" stop-opacity="0" />
                    </linearGradient>
                  </defs>
                  <path d={chart_fill_path(pad_rpm(@requests_per_minute, 60))} fill="url(#chartFill)" />
                  <path
                    d={chart_line_path(pad_rpm(@requests_per_minute, 60))}
                    fill="none"
                    stroke="hsl(239, 84%, 67%)"
                    stroke-width="1.5"
                  />
                </svg>
              </div>
            </div>

            <div class="rounded-lg border border-base-300/50 bg-base-100 p-3">
              <div class="flex items-center justify-between mb-2">
                <p class="text-sm font-semibold text-base-content">Routing Chain</p>
                <p class="text-xs text-base-content/40">
                  {pluralize(length(@selected_router_steps), "step")}
                </p>
              </div>
              <div class="space-y-1.5">
                <%= for {step, idx} <- Enum.with_index(@selected_router_steps) do %>
                  <div class={[
                    "flex items-center justify-between rounded-lg px-2.5 py-2",
                    idx == 0 && "bg-accent/5 border-l-2 border-accent",
                    idx > 0 && "bg-secondary/50"
                  ]}>
                    <div class="flex items-center gap-2">
                      <div class="w-5 h-5 rounded flex items-center justify-center shrink-0 bg-base-200">
                        <.provider_logo
                          slug={Registry.to_key_slug(step.provider, step.plan_type || "standard")}
                          class="w-3.5 h-3.5"
                        />
                      </div>
                      <span class="text-sm font-medium text-base-content">
                        {step.provider} / {step.model}
                      </span>
                    </div>
                    <span class={[
                      "rounded-full px-2 py-0.5 text-xs font-semibold",
                      idx == 0 && "bg-green-50 text-success",
                      idx == 1 && "bg-amber-50 text-warning",
                      idx >= 2 && "bg-red-50 text-error"
                    ]}>
                      <%= cond do %>
                        <% idx == 0 -> %>
                          Primary
                        <% idx == 1 -> %>
                          Fallback
                        <% true -> %>
                          Last Resort
                      <% end %>
                    </span>
                  </div>
                <% end %>
                <p :if={Enum.empty?(@selected_router_steps)} class="text-sm text-base-content/40 py-2">
                  No routing steps configured
                </p>
              </div>
            </div>
          </div>

          <div class="rounded-lg border border-base-300/50 bg-base-100 overflow-hidden">
            <div class="flex items-center justify-between border-b border-base-300/50 px-4 py-2.5">
              <p class="text-sm font-semibold text-base-content">Recent Requests</p>
              <div class="flex items-center gap-3">
                <span class="flex items-center gap-1.5 text-xs text-base-content/40">
                  <span class="h-1.5 w-1.5 rounded-full bg-accent animate-soft-pulse"></span>
                  Streaming
                </span>
                <.link
                  navigate={~p"/logs?router_id=#{@selected_router.id}"}
                  class="text-xs text-primary hover:underline"
                >
                  View all
                </.link>
              </div>
            </div>
            <table class="w-full text-left">
              <thead>
                <tr class="border-b border-base-300/50 bg-secondary/30">
                  <th class="px-4 py-2 text-xs font-medium text-base-content/50">Time</th>
                  <th class="px-4 py-2 text-xs font-medium text-base-content/50">Status</th>
                  <th class="px-4 py-2 text-xs font-medium text-base-content/50 hidden sm:table-cell">
                    Provider / Model
                  </th>
                  <th class="px-4 py-2 text-xs font-medium text-base-content/50 hidden md:table-cell">
                    Tokens
                  </th>
                  <th class="px-4 py-2 text-xs font-medium text-base-content/50">Latency</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300/30">
                <%= for log <- @recent_logs do %>
                  <tr class="hover:bg-secondary/20 transition-colors">
                    <td class="px-4 py-2 text-sm font-mono text-base-content/50">
                      {format_time(log.inserted_at)}
                    </td>
                    <td class="px-4 py-2">
                      <span class={[
                        "rounded-full px-2 py-0.5 text-xs font-semibold",
                        log.status == "success" && "bg-green-50 text-success",
                        log.status == "fallback" && "bg-amber-50 text-warning",
                        log.status == "error" && "bg-red-50 text-error",
                        log.status == "pending" && "bg-secondary text-base-content/50"
                      ]}>
                        {log.status}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-sm hidden sm:table-cell">
                      <%= if is_list(Map.get(log, :attempted_steps)) and length(log.attempted_steps) > 1 do %>
                        <div class="flex items-center gap-1">
                          <span class="line-through text-base-content/30">
                            {List.first(log.attempted_steps)["provider"]}
                          </span>
                          <span class="text-base-content/30 mx-1">&rarr;</span>
                          <div class="flex items-center gap-1.5">
                            <div class="w-3.5 h-3.5 rounded flex items-center justify-center shrink-0 bg-base-200">
                              <.provider_logo
                                slug={normalize_slug(log.final_provider)}
                                class="w-2.5 h-2.5"
                              />
                            </div>
                            <span class="font-medium text-base-content">
                              {log.final_provider} / {log.final_model}
                            </span>
                          </div>
                        </div>
                      <% else %>
                        <div class="flex items-center gap-1.5">
                          <div class="w-3.5 h-3.5 rounded flex items-center justify-center shrink-0 bg-base-200">
                            <.provider_logo
                              slug={normalize_slug(log.final_provider)}
                              class="w-2.5 h-2.5"
                            />
                          </div>
                          <span class="font-medium text-base-content">{log.final_provider}</span>
                          <span class="text-base-content/40"> / </span>
                          <span class="text-base-content/60">{log.final_model}</span>
                        </div>
                      <% end %>
                    </td>
                    <td class="px-4 py-2 text-sm font-mono text-base-content/50 hidden md:table-cell">
                      {Map.get(log, :total_tokens) || "-"}
                    </td>
                    <td class="px-4 py-2 text-sm font-mono text-base-content/50">
                      {if Map.get(log, :latency_ms), do: "#{log.latency_ms}ms", else: "-"}
                    </td>
                  </tr>
                <% end %>
                <tr :if={Enum.empty?(@recent_logs)}>
                  <td colspan="5" class="px-4 py-8 text-center text-sm text-base-content/40">
                    No requests yet
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% else %>
        <div class="rounded-lg border border-base-300/50 bg-base-100 p-8 text-center">
          <div class="max-w-md mx-auto">
            <div class="w-16 h-16 mx-auto mb-6 rounded-lg bg-secondary flex items-center justify-center">
              <.icon name="hero-bolt" class="size-8 text-accent" />
            </div>
            <h2 class="text-xl font-semibold mb-2 font-display">Welcome to DodoRouter</h2>
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
      rate >= 95 -> "text-success"
      rate >= 80 -> "text-warning"
      true -> "text-error"
    end
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

  defp chart_fill_path([]), do: "M0,60 L200,60 L0,60 Z"
  defp chart_fill_path(buckets), do: "#{chart_line_path(buckets)} L200,60 L0,60 Z"

  defp chart_line_path([]), do: "M0,60 L200,60"

  defp chart_line_path(buckets) do
    max_count = buckets |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end) |> max(1)
    count = length(buckets)

    buckets
    |> Enum.with_index()
    |> Enum.map(fn {bucket, idx} ->
      x = if count > 1, do: idx / (count - 1) * 200.0, else: 100.0
      y = 60.0 - max(3.0, bucket.count / max_count * 55.0 + 2.0)
      "#{if idx == 0, do: "M", else: "L"}#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp router_color(idx) do
    Enum.at(@router_colors, rem(idx, length(@router_colors)))
  end
end
