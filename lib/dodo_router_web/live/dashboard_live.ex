defmodule DodoRouterWeb.DashboardLive do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Routers, Logs}
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouterWeb.Components.Charts

  @refresh_interval_ms 5_000
  @router_colors ~w(blue purple amber rose emerald sky orange indigo)

  # Time-range presets: window in hours + bucket size for the time series
  @ranges %{
    "1h" => %{hours: 1, bucket: :minute, label: "1h"},
    "24h" => %{hours: 24, bucket: :hour, label: "24h"},
    "7d" => %{hours: 7 * 24, bucket: :day, label: "7d"},
    "30d" => %{hours: 30 * 24, bucket: :day, label: "30d"}
  }
  @range_order ~w(1h 24h 7d 30d)
  @default_range "24h"

  @impl true
  def mount(params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    selected_router = find_selected_router(routers, params["router_id"])

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:routers, routers)
      |> assign(:selected_router, selected_router)
      |> assign(:range, valid_range(params["range"]))
      |> assign(:spend_view, "chart")
      |> assign(:stats, nil)
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
  def handle_params(params, _url, socket) do
    router = find_selected_router(socket.assigns.routers, params["router_id"])

    socket =
      socket
      |> assign(:selected_router, router)
      |> assign(:range, valid_range(params["range"]))

    socket =
      if router do
        socket
        |> assign(:loading, true)
        |> load_stats()
        |> assign(:loading, false)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_router", %{"router_id" => router_id}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/dashboard?router_id=#{router_id}&range=#{socket.assigns.range}")}
  end

  def handle_event("select_range", %{"range" => range}, socket) do
    params = %{range: valid_range(range)}

    params =
      if socket.assigns.selected_router,
        do: Map.put(params, :router_id, socket.assigns.selected_router.id),
        else: params

    {:noreply, push_patch(socket, to: ~p"/dashboard?#{params}")}
  end

  def handle_event("spend_view", %{"view" => view}, socket) when view in ~w(chart table) do
    {:noreply, assign(socket, :spend_view, view)}
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

  defp valid_range(range) when is_map_key(@ranges, range), do: range
  defp valid_range(_), do: @default_range

  defp find_selected_router(routers, router_id) when is_binary(router_id) do
    Enum.find(routers, &(&1.id == router_id)) || List.first(routers)
  end

  defp find_selected_router(routers, _router_id) do
    List.first(routers)
  end

  defp load_stats(socket) do
    router = socket.assigns.selected_router
    %{hours: hours, bucket: bucket} = @ranges[socket.assigns.range]

    timeseries = Logs.timeseries(router, hours: hours, bucket: bucket)
    spend_ts = Logs.spend_timeseries(router, hours: hours, bucket: bucket)
    latency_ts = Logs.latency_timeseries(router, hours: hours, bucket: bucket)
    by_provider = Logs.stats_by_provider(router, hours: hours)

    provider_colors = provider_color_map(spend_ts.series, by_provider)

    socket
    |> assign(:stats, Logs.stats(router, hours: hours))
    |> assign(
      :stats_by_provider,
      Enum.sort_by(by_provider, &decimal_float(&1.total_cost_usd), :desc)
    )
    |> assign(:latency_percentiles, Logs.latency_percentiles(router, hours: hours))
    |> assign(:cache_stats, Logs.cache_stats(router, hours: hours))
    |> assign(:spend_by_model, Logs.spend_by_model(router, hours: hours))
    |> assign(:bucket_labels, Enum.map(timeseries, &bucket_label(&1.bucket, bucket)))
    |> assign(:timeseries, timeseries)
    |> assign(:spend_series, spend_chart_series(spend_ts, provider_colors))
    |> assign(:spend_buckets, spend_ts.buckets)
    |> assign(:latency_series, latency_chart_series(latency_ts))
    |> assign(:provider_colors, provider_colors)
    |> assign(:selected_router_steps, Routers.list_routing_steps(router))
    |> assign(:recent_logs, Logs.list_logs(router, limit: 8))
  end

  # Colors follow the provider (alphabetical slot assignment), so a provider
  # keeps its hue across refreshes, range changes, and both spend charts.
  defp provider_color_map(spend_series, by_provider) do
    (Enum.map(spend_series, & &1.provider) ++ Enum.map(by_provider, & &1.provider))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.with_index()
    |> Map.new(fn {provider, idx} -> {provider, Charts.series_color(idx)} end)
  end

  defp spend_chart_series(%{series: series}, provider_colors) do
    series
    |> Enum.map(fn s ->
      %{
        name: s.provider,
        color: provider_colors[s.provider],
        values: Enum.map(s.values, &decimal_float/1)
      }
    end)
    |> fold_series_overflow()
  end

  # Never more than 8 hues: past that, the smallest series fold into "Other".
  defp fold_series_overflow(series) when length(series) <= 8, do: series

  defp fold_series_overflow(series) do
    {kept, folded} =
      series
      |> Enum.sort_by(fn s -> -Enum.sum(s.values) end)
      |> Enum.split(7)

    other_values =
      folded
      |> Enum.map(& &1.values)
      |> Enum.zip_with(&Enum.sum/1)

    kept = Enum.sort_by(kept, & &1.name)
    kept ++ [%{name: "Other", color: "var(--viz-other)", values: other_values}]
  end

  defp latency_chart_series(latency_ts) do
    [
      %{name: "p50", color: "var(--viz-ord-lo)", values: Enum.map(latency_ts, & &1.p50)},
      %{name: "p95", color: "var(--viz-ord-hi)", values: Enum.map(latency_ts, & &1.p95)}
    ]
  end

  defp status_series(timeseries) do
    [
      %{
        name: "Success",
        color: "var(--color-success)",
        values: Enum.map(timeseries, & &1.success)
      },
      %{
        name: "Fallback",
        color: "var(--color-warning)",
        values: Enum.map(timeseries, & &1.fallback)
      },
      %{name: "Error", color: "var(--color-error)", values: Enum.map(timeseries, & &1.error)}
    ]
  end

  defp bucket_label(dt, :day), do: Calendar.strftime(dt, "%b %d")
  defp bucket_label(dt, _), do: Calendar.strftime(dt, "%H:%M")

  defp decimal_float(nil), do: 0.0
  defp decimal_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_float(v) when is_number(v), do: v / 1

  defp range_subtitle("1h"), do: "Last 60 minutes"
  defp range_subtitle("24h"), do: "Last 24 hours"
  defp range_subtitle("7d"), do: "Last 7 days"
  defp range_subtitle("30d"), do: "Last 30 days"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :range_order, @range_order)

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
        <div class="flex items-center gap-2 mb-4 overflow-x-auto pb-1">
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
        <div class="flex items-center justify-between mb-4">
          <div
            id="range-picker"
            class="inline-flex items-center rounded-lg border border-base-300/50 bg-base-100 p-0.5"
          >
            <button
              :for={range <- @range_order}
              phx-click="select_range"
              phx-value-range={range}
              class={[
                "rounded-md px-3 py-1 text-xs font-semibold transition-colors",
                @range == range && "bg-accent text-accent-content shadow-sm",
                @range != range && "text-base-content/60 hover:text-base-content"
              ]}
            >
              {range}
            </button>
          </div>
          <p class="text-xs text-base-content/40">{range_subtitle(@range)}</p>
        </div>

        <div class={[
          "transition-opacity duration-200",
          @loading && "opacity-50"
        ]}>
          <div class="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-3 mb-4">
            <Charts.stat_tile
              id="kpi-spend"
              label="Total Spend"
              value={Charts.format_usd(@stats.total_cost_usd)}
              subtext={avg_cost_subtext(@stats)}
              spark={Enum.map(@timeseries, &decimal_float(&1.cost_usd))}
            />
            <Charts.stat_tile
              id="kpi-requests"
              label="Requests"
              value={Charts.format_compact(@stats.total_requests)}
              subtext={"#{Charts.format_compact(@stats.successful_requests)} ok · #{Charts.format_compact(@stats.error_requests)} failed"}
              spark={Enum.map(@timeseries, & &1.total)}
            />
            <Charts.stat_tile
              id="kpi-success"
              label="Success Rate"
              value={success_rate(@stats)}
              value_class={success_color(@stats)}
              subtext={
                if @stats.fallback_requests > 0,
                  do: "#{@stats.fallback_requests} recovered by fallback",
                  else: "No fallbacks needed"
              }
            />
            <Charts.stat_tile
              id="kpi-latency"
              label="p95 Latency"
              value={Charts.format_ms(@latency_percentiles.p95)}
              subtext={"p50 #{Charts.format_ms(@latency_percentiles.p50)}"}
            />
            <Charts.stat_tile
              id="kpi-tokens"
              label="Total Tokens"
              value={Charts.format_compact(@stats.total_tokens)}
              subtext={"#{Charts.format_compact(@stats.prompt_tokens)} in / #{Charts.format_compact(@stats.completion_tokens)} out"}
            />
            <Charts.stat_tile
              id="kpi-cache"
              label="Cache Hit Rate"
              value={if @cache_stats.hit_rate > 0, do: "#{@cache_stats.hit_rate}%", else: "-"}
              subtext={
                if @cache_stats.cache_read_tokens > 0,
                  do: "#{Charts.format_compact(@cache_stats.cache_read_tokens)} tokens from cache",
                  else: "No cache data"
              }
            />
          </div>

          <div class="rounded-lg border border-base-300/50 bg-base-100 p-4 mb-4">
            <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
              <div>
                <p class="text-sm font-semibold text-base-content">Spend</p>
                <p class="text-xs text-base-content/40">
                  By provider, {String.downcase(range_subtitle(@range))}
                </p>
              </div>
              <div class="flex items-center gap-3">
                <Charts.legend :if={length(@spend_series) > 1} series={@spend_series} />
                <div class="inline-flex items-center rounded-lg border border-base-300/50 p-0.5">
                  <button
                    :for={{view, label} <- [{"chart", "Chart"}, {"table", "Table"}]}
                    phx-click="spend_view"
                    phx-value-view={view}
                    class={[
                      "rounded-md px-2 py-0.5 text-xs font-medium transition-colors",
                      @spend_view == view && "bg-secondary text-base-content",
                      @spend_view != view && "text-base-content/50 hover:text-base-content"
                    ]}
                  >
                    {label}
                  </button>
                </div>
              </div>
            </div>
            <%= if @spend_view == "chart" do %>
              <Charts.column_chart
                id="spend-chart"
                labels={@bucket_labels}
                series={@spend_series}
                unit={:usd}
                height={210}
                empty_label="No spend recorded in this range"
              />
            <% else %>
              <div class="max-h-64 overflow-y-auto">
                <table class="w-full text-left text-sm">
                  <thead class="sticky top-0 bg-base-100">
                    <tr class="border-b border-base-300/50">
                      <th class="py-1.5 pr-4 text-xs font-medium text-base-content/50">Time</th>
                      <th
                        :for={s <- @spend_series}
                        class="py-1.5 pr-4 text-xs font-medium text-base-content/50"
                      >
                        {s.name}
                      </th>
                      <th class="py-1.5 text-xs font-medium text-base-content/50">Total</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-300/30">
                    <tr :for={{label, idx} <- Enum.with_index(@bucket_labels)}>
                      <td class="py-1.5 pr-4 font-mono text-xs text-base-content/50">{label}</td>
                      <td :for={s <- @spend_series} class="py-1.5 pr-4 tabular-nums text-xs">
                        {Charts.format_usd(Enum.at(s.values, idx))}
                      </td>
                      <td class="py-1.5 tabular-nums text-xs font-semibold">
                        {Charts.format_usd(
                          Enum.sum(Enum.map(@spend_series, &(Enum.at(&1.values, idx) || 0)))
                        )}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-3 mb-4">
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-4">
              <div class="flex items-center justify-between mb-3">
                <div>
                  <p class="text-sm font-semibold text-base-content">Requests</p>
                  <p class="text-xs text-base-content/40">By outcome</p>
                </div>
                <Charts.legend series={status_series(@timeseries)} />
              </div>
              <Charts.column_chart
                id="requests-chart"
                labels={@bucket_labels}
                series={status_series(@timeseries)}
                unit={:count}
                height={170}
              />
            </div>

            <div class="rounded-lg border border-base-300/50 bg-base-100 p-4">
              <div class="flex items-center justify-between mb-3">
                <div>
                  <p class="text-sm font-semibold text-base-content">Latency</p>
                  <p class="text-xs text-base-content/40">Percentiles per bucket</p>
                </div>
                <Charts.legend series={@latency_series} kind={:line} />
              </div>
              <Charts.line_chart
                id="latency-chart"
                labels={@bucket_labels}
                series={@latency_series}
                unit={:ms}
                height={170}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-5 gap-3 mb-4">
            <div class="rounded-lg border border-base-300/50 bg-base-100 p-4 lg:col-span-2">
              <div class="mb-3">
                <p class="text-sm font-semibold text-base-content">Spend by Model</p>
                <p class="text-xs text-base-content/40">Top models by cost</p>
              </div>
              <Charts.hbar_list
                id="model-spend"
                rows={model_rows(@spend_by_model)}
                empty_label="No model spend in this range"
              />
            </div>

            <div class="rounded-lg border border-base-300/50 bg-base-100 p-4 lg:col-span-3">
              <div class="mb-3">
                <p class="text-sm font-semibold text-base-content">Providers</p>
                <p class="text-xs text-base-content/40">Share of spend and reliability</p>
              </div>
              <Charts.share_bar id="provider-share" segments={provider_segments(assigns)} />
              <table class="mt-3 w-full text-left text-sm">
                <thead>
                  <tr class="border-b border-base-300/50">
                    <th class="py-1.5 pr-3 text-xs font-medium text-base-content/50">Provider</th>
                    <th class="py-1.5 pr-3 text-xs font-medium text-base-content/50">Spend</th>
                    <th class="py-1.5 pr-3 text-xs font-medium text-base-content/50">Requests</th>
                    <th class="py-1.5 pr-3 text-xs font-medium text-base-content/50">Errors</th>
                    <th class="py-1.5 pr-3 text-xs font-medium text-base-content/50 hidden sm:table-cell">
                      Tokens
                    </th>
                    <th class="py-1.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                      Avg Latency
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-base-300/30">
                  <tr :for={p <- @stats_by_provider}>
                    <td class="py-2 pr-3">
                      <div class="flex items-center gap-2">
                        <span
                          class="h-2.5 w-2.5 shrink-0 rounded-sm"
                          style={"background: #{@provider_colors[p.provider]}"}
                        >
                        </span>
                        <div class="flex h-4 w-4 shrink-0 items-center justify-center rounded bg-base-200">
                          <.provider_logo slug={normalize_slug(p.provider)} class="h-3 w-3" />
                        </div>
                        <span class="font-medium text-base-content">{p.provider}</span>
                      </div>
                    </td>
                    <td class="py-2 pr-3 tabular-nums font-semibold">
                      {Charts.format_usd(p.total_cost_usd)}
                    </td>
                    <td class="py-2 pr-3 tabular-nums text-base-content/70">
                      {Charts.format_compact(p.total_requests)}
                    </td>
                    <td class={[
                      "py-2 pr-3 tabular-nums",
                      p.error_requests > 0 && "text-error font-medium",
                      p.error_requests == 0 && "text-base-content/40"
                    ]}>
                      {p.error_requests}
                    </td>
                    <td class="py-2 pr-3 tabular-nums text-base-content/70 hidden sm:table-cell">
                      {Charts.format_compact(p.total_tokens)}
                    </td>
                    <td class="py-2 tabular-nums text-base-content/70 hidden md:table-cell">
                      {Charts.format_ms(p.avg_latency_ms)}
                    </td>
                  </tr>
                  <tr :if={@stats_by_provider == []}>
                    <td colspan="6" class="py-6 text-center text-xs text-base-content/40">
                      No provider traffic in this range
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
            <div class="rounded-lg border border-base-300/50 bg-base-100 overflow-hidden lg:col-span-2">
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
                      Cost
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
                        {if Map.get(log, :estimated_cost_usd),
                          do: Charts.format_usd(log.estimated_cost_usd),
                          else: "-"}
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

            <div class="rounded-lg border border-base-300/50 bg-base-100 p-4">
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
                    <div class="flex items-center gap-2 min-w-0">
                      <div class="w-5 h-5 rounded flex items-center justify-center shrink-0 bg-base-200">
                        <.provider_logo
                          slug={Registry.to_key_slug(step.provider, step.plan_type || "standard")}
                          class="w-3.5 h-3.5"
                        />
                      </div>
                      <span class="text-sm font-medium text-base-content truncate">
                        {step.provider} / {step.model}
                      </span>
                    </div>
                    <span class={[
                      "rounded-full px-2 py-0.5 text-xs font-semibold shrink-0",
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

  defp avg_cost_subtext(%{total_requests: 0}), do: "No requests yet"

  defp avg_cost_subtext(%{total_requests: total, total_cost_usd: cost}) do
    "#{Charts.format_usd(decimal_float(cost) / total)} avg/request"
  end

  # Top 8 models by spend; nominal categories share slot-1 hue.
  defp model_rows(spend_by_model) do
    spend_by_model
    |> Enum.filter(&(decimal_float(&1.cost_usd) > 0))
    |> Enum.take(8)
    |> Enum.map(fn m ->
      %{
        name: m.model,
        value: decimal_float(m.cost_usd),
        display: Charts.format_usd(m.cost_usd),
        subtext: "#{m.provider} · #{Charts.format_compact(m.total_requests)} requests"
      }
    end)
  end

  defp provider_segments(assigns) do
    for p <- assigns.stats_by_provider, decimal_float(p.total_cost_usd) > 0 do
      %{
        name: p.provider,
        value: decimal_float(p.total_cost_usd),
        display: Charts.format_usd(p.total_cost_usd),
        color: assigns.provider_colors[p.provider]
      }
    end
  end

  defp success_rate(%{total_requests: 0}), do: "-"

  defp success_rate(%{total_requests: total, successful_requests: success}) do
    "#{round(success / total * 100)}%"
  end

  defp success_color(%{total_requests: 0}), do: "text-base-content"

  defp success_color(%{total_requests: total, successful_requests: success}) do
    rate = success / total * 100

    cond do
      rate >= 95 -> "text-success"
      rate >= 80 -> "text-warning"
      true -> "text-error"
    end
  end

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp router_color(idx) do
    Enum.at(@router_colors, rem(idx, length(@router_colors)))
  end
end
