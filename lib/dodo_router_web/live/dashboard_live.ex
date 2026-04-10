defmodule DodoRouterWeb.DashboardLive do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Projects, Logs}

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_projects(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:projects, projects)
      |> assign(:selected_project, List.first(projects))
      |> assign(:stats, nil)
      |> assign(:stats_by_provider, [])
      |> assign(:latency_percentiles, %{})
      |> assign(:failure_breakdown, [])
      |> assign(:requests_per_minute, [])
      |> assign(:live_events, [])

    socket =
      if socket.assigns.selected_project do
        load_stats(socket)
      else
        socket
      end

    if connected?(socket) do
      schedule_refresh()

      if socket.assigns.selected_project do
        Phoenix.PubSub.subscribe(
          DodoRouter.PubSub,
          "project:#{socket.assigns.selected_project.id}:events"
        )
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"project_id" => project_id}, _url, socket) do
    project = Projects.get_project!(socket.assigns.current_user, project_id)

    if socket.assigns.selected_project do
      Phoenix.PubSub.unsubscribe(
        DodoRouter.PubSub,
        "project:#{socket.assigns.selected_project.id}:events"
      )
    end

    Phoenix.PubSub.subscribe(DodoRouter.PubSub, "project:#{project.id}:events")

    socket =
      socket
      |> assign(:selected_project, project)
      |> assign(:live_events, [])
      |> load_stats()

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_project", %{"project_id" => project_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dashboard?project_id=#{project_id}")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()

    socket =
      if socket.assigns.selected_project do
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
    project = socket.assigns.selected_project

    socket
    |> assign(:stats, Logs.stats(project, hours: 24))
    |> assign(:stats_by_provider, Logs.stats_by_provider(project, hours: 24))
    |> assign(:latency_percentiles, Logs.latency_percentiles(project, hours: 24))
    |> assign(:failure_breakdown, Logs.failure_breakdown(project, hours: 24))
    |> assign(:requests_per_minute, Logs.requests_per_minute(project, minutes: 60))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto">
      <.header>
        Dashboard
        <:actions>
          <select phx-change="select_project" name="project_id" class="rounded-md border-gray-300">
            <option :for={p <- @projects} value={p.id} selected={@selected_project && p.id == @selected_project.id}>
              <%= p.name %>
            </option>
          </select>
        </:actions>
      </.header>

      <div :if={@selected_project && @stats} class="mt-8">
        <div class="grid grid-cols-5 gap-4">
          <.stat_card title="Requests (24h)" value={@stats.total_requests} />
          <.stat_card title="Success Rate" value={success_rate(@stats)} color={success_color(@stats)} />
          <.stat_card title="Fallback Rate" value={fallback_rate(@stats)} color="yellow" />
          <.stat_card title="Tokens Used" value={format_number(@stats.total_tokens)} />
          <.stat_card title="Est. Cost" value={format_cost(@stats.total_cost_usd)} />
        </div>

        <div class="mt-8 grid grid-cols-3 gap-4">
          <.stat_card title="p50 Latency" value={format_latency(@latency_percentiles.p50)} />
          <.stat_card title="p95 Latency" value={format_latency(@latency_percentiles.p95)} />
          <.stat_card title="p99 Latency" value={format_latency(@latency_percentiles.p99)} />
        </div>

        <div class="mt-8 grid grid-cols-2 gap-8">
          <div class="bg-white border rounded-lg p-4">
            <h3 class="font-semibold mb-4">Requests per Minute (last hour)</h3>
            <div class="h-32 flex items-end gap-1">
              <%= for bucket <- pad_rpm(@requests_per_minute, 60) do %>
                <div
                  class="flex-1 bg-blue-500 rounded-t"
                  style={"height: #{bucket_height(bucket, @requests_per_minute)}%"}
                  title={"#{bucket.count} requests"}
                >
                </div>
              <% end %>
            </div>
          </div>

          <div class="bg-white border rounded-lg p-4">
            <h3 class="font-semibold mb-4">By Provider (24h)</h3>
            <div class="space-y-3">
              <div :for={stat <- @stats_by_provider} class="flex items-center gap-4">
                <span class="w-24 font-medium"><%= stat.provider %></span>
                <div class="flex-1 bg-gray-100 rounded h-6 overflow-hidden">
                  <div
                    class="h-full bg-blue-500"
                    style={"width: #{provider_percentage(stat, @stats)}%"}
                  >
                  </div>
                </div>
                <span class="w-16 text-right text-sm"><%= stat.total_requests %></span>
              </div>
            </div>
          </div>
        </div>

        <div :if={length(@failure_breakdown) > 0} class="mt-8">
          <div class="bg-white border rounded-lg p-4">
            <h3 class="font-semibold mb-4">Failures (24h)</h3>
            <.table id="failures" rows={@failure_breakdown}>
              <:col :let={f} label="Provider"><%= f.provider %></:col>
              <:col :let={f} label="Model"><%= f.model %></:col>
              <:col :let={f} label="Status">
                <span class={"px-2 py-0.5 rounded text-xs font-medium #{if f.status == "error", do: "bg-red-100 text-red-800", else: "bg-yellow-100 text-yellow-800"}"}>
                  <%= f.status %>
                </span>
              </:col>
              <:col :let={f} label="Count"><%= f.count %></:col>
            </.table>
          </div>
        </div>

        <div class="mt-8">
          <div class="bg-white border rounded-lg p-4">
            <h3 class="font-semibold mb-4">Live Events</h3>
            <div class="space-y-2 max-h-64 overflow-y-auto">
              <div :for={event <- @live_events} class={"p-2 rounded text-sm #{event_class(event)}"}>
                <span class="font-mono"><%= event.provider %>/<%= event.model %></span>
                <span class="ml-4"><%= event.latency_ms %>ms</span>
                <span :if={event.had_fallback} class="ml-2 text-orange-600">(fallback)</span>
                <span class="float-right text-gray-500"><%= format_event_time(event.timestamp) %></span>
              </div>
              <p :if={Enum.empty?(@live_events)} class="text-gray-500 text-sm">
                Waiting for requests...
              </p>
            </div>
          </div>
        </div>
      </div>

      <div :if={!@selected_project} class="mt-12 text-center text-gray-500">
        No projects yet. <.link navigate={~p"/projects/new"} class="text-blue-600 hover:underline">Create one</.link> to get started.
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    color_class =
      case assigns[:color] do
        "green" -> "text-green-600"
        "yellow" -> "text-yellow-600"
        "red" -> "text-red-600"
        _ -> ""
      end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="p-4 bg-white border rounded-lg">
      <p class="text-sm text-gray-500"><%= @title %></p>
      <p class={"text-2xl font-semibold mt-1 #{@color_class}"}><%= @value %></p>
    </div>
    """
  end

  defp success_rate(%{total_requests: 0}), do: "-"
  defp success_rate(%{total_requests: total, successful_requests: success}) do
    "#{round(success / total * 100)}%"
  end

  defp success_color(%{total_requests: 0}), do: nil
  defp success_color(%{total_requests: total, successful_requests: success}) do
    rate = success / total * 100
    cond do
      rate >= 99 -> "green"
      rate >= 95 -> "yellow"
      true -> "red"
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

  defp event_class(%{status: :success}), do: "bg-green-50"
  defp event_class(%{status: :fallback}), do: "bg-yellow-50"
  defp event_class(_), do: "bg-red-50"

  defp provider_percentage(_stat, %{total_requests: 0}), do: 0
  defp provider_percentage(stat, %{total_requests: total}) do
    round(stat.total_requests / total * 100)
  end

  defp pad_rpm(buckets, target_count) do
    existing = length(buckets)
    padding = max(0, target_count - existing)
    List.duplicate(%{count: 0}, padding) ++ buckets
  end

  defp bucket_height(_bucket, []), do: 0
  defp bucket_height(%{count: 0}, _all), do: 0
  defp bucket_height(%{count: count}, all) do
    max_count = Enum.map(all, & &1.count) |> Enum.max(fn -> 1 end)
    round(count / max_count * 100)
  end
end
