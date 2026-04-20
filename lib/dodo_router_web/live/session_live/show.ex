defmodule DodoRouterWeb.SessionLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Routers

  @impl true
  def mount(%{"router_id" => router_id, "session_id" => session_id}, _session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:logs")
    end

    socket =
      socket
      |> assign(:router, router)
      |> assign(:session_id, session_id)
      |> assign(:page_title, "Session #{session_id}")
      |> load_data()

    {:ok, socket}
  end

  def mount(_params, _socket_session, socket) do
    {:ok, redirect(socket, to: ~p"/routers")}
  end

  @impl true
  def handle_info({:log_created, log}, socket) do
    if log.session_id == socket.assigns.session_id do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <a href={~p"/routers/#{@router.id}/sessions"} class="btn btn-ghost btn-sm btn-circle">←</a>
        <div>
          <h1 class="text-xl font-bold">
            {if @session_name, do: @session_name, else: "Session"}
          </h1>
          <p class="text-sm font-mono text-base-content/50">{@session_id}</p>
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
          <div class="stat-title text-xs">Avg Latency</div>
          <div class="stat-value text-lg">{format_latency(@stats.avg_latency_ms)}ms</div>
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
      
    <!-- Request timeline -->
      <h2 class="text-lg font-semibold mb-3">Requests</h2>
      <div class="space-y-2">
        <%= for log <- @logs do %>
          <a
            href={~p"/logs/#{log.id}" <> "?return_to=" <> URI.encode_www_form("/routers/#{@router.id}/sessions/#{@session_id}")}
            class="block bg-base-100 border border-base-300 rounded-lg p-3 hover:border-primary transition-colors"
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class={[
                  "badge badge-sm",
                  if(log.status in ["success", "fallback"], do: "badge-success", else: "badge-error")
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
      </div>
    </div>
    """
  end

  defp load_data(socket) do
    router = socket.assigns.router
    session_id = socket.assigns.session_id

    stats = Logs.session_stats(router, session_id)
    logs = Logs.list_logs_by_session(router, session_id, limit: 100)

    session_name =
      case logs do
        [first | _] -> first.session_name
        _ -> nil
      end

    socket
    |> assign(:stats, stats)
    |> assign(:logs, logs)
    |> assign(:session_name, session_name)
  end

  defp format_latency(nil), do: "0"
  defp format_latency(%Decimal{} = ms), do: ms |> Decimal.round(0) |> Decimal.to_integer()
  defp format_latency(ms), do: round(ms)
end
