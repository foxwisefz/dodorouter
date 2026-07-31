defmodule DodoRouterWeb.SessionLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
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
      |> assign(:editing_name, false)
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
  def handle_event("edit_name", _params, socket) do
    {:noreply, assign(socket, :editing_name, true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_name, false)}
  end

  def handle_event("save_name", %{"session_name" => session_name}, socket) do
    router = socket.assigns.router
    session_id = socket.assigns.session_id

    Logs.update_session_name(router, session_id, session_name)

    {:noreply,
     socket
     |> assign(:editing_name, false)
     |> assign(:session_name, session_name)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <a href={~p"/routers/#{@router.id}/sessions"} class="btn btn-ghost btn-sm btn-circle">←</a>
        <div class="flex-1">
          <%= if @editing_name do %>
            <form phx-submit="save_name" class="flex items-center gap-2">
              <input
                type="text"
                name="session_name"
                value={@session_name || ""}
                placeholder="Session name"
                class="input input-sm input-bordered w-full max-w-xs"
                phx-mounted={JS.focus()}
              />
              <button type="submit" class="btn btn-sm btn-primary">Save</button>
              <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-ghost">
                Cancel
              </button>
            </form>
          <% else %>
            <div class="flex items-center gap-2">
              <h1 class="text-xl font-bold">
                {if @session_name, do: @session_name, else: "Session"}
              </h1>
              <button phx-click="edit_name" class="btn btn-ghost btn-xs" title="Edit name">
                <.icon name="hero-pencil" class="size-3" />
              </button>
            </div>
          <% end %>
          <p class="text-sm font-mono text-base-content/50">{@session_id}</p>
        </div>
      </div>
      
    <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
        <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
          <div class="stat-title text-xs">Requests</div>
          <div class="stat-value text-lg">{@stats.request_count}</div>
        </div>
        <div class="stat bg-base-100 border border-base-300 rounded-lg p-3">
          <div class="stat-title text-xs">Cost</div>
          <div id="session-cost" class="stat-value text-lg">
            {format_usd(@stats.total_cost_usd)}
          </div>
          <div
            :if={would_be_cost(@stats)}
            class="text-xs text-base-content/50 mt-0.5"
            title="Traffic served through subscription/coding-plan keys has no marginal per-token cost. This is what the same tokens would cost at pay-as-you-go API list prices."
          >
            ~{format_usd(would_be_cost(@stats))} at API rates
          </div>
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
            class={[
              "block p-3 rounded-lg text-sm transition-colors",
              log.status == "pending" && "bg-info/10 animate-pulse",
              log.status == "success" && "bg-success/10 hover:bg-success/20",
              log.status == "fallback" && "bg-warning/10 hover:bg-warning/20",
              log.status == "error" && "bg-error/10 hover:bg-error/20"
            ]}
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class={[
                  "w-2 h-2 rounded-full shrink-0",
                  log.status == "pending" && "bg-info",
                  log.status == "success" && "bg-success",
                  log.status == "fallback" && "bg-warning",
                  log.status == "error" && "bg-error"
                ]}>
                </span>
                <div class="flex items-center gap-2">
                  <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
                    <.provider_logo slug={normalize_slug(log.final_provider)} class="w-3 h-3" />
                  </div>
                  <span class="font-mono text-base-content/80">
                    {log.final_provider}/{log.final_model}
                  </span>
                </div>
                <span
                  :if={log.call_type}
                  class="px-1.5 py-0.5 rounded text-xs font-medium bg-base-300/50 text-base-content/70"
                >
                  {call_type_label(log.call_type)}
                </span>
                <span class={[
                  "px-1.5 py-0.5 rounded text-xs font-medium",
                  status_badge_class(log.status)
                ]}>
                  {log.status}
                </span>
              </div>
              <div class="flex items-center gap-4 text-base-content/50 text-sm shrink-0">
                <.log_cost log={log} />
                <span :if={Map.get(log, :latency_ms)} class="font-mono">{log.latency_ms}ms</span>
                <span class="font-mono text-xs">{format_time(log.inserted_at)}</span>
              </div>
            </div>
            <div
              :if={last_message_preview(log)}
              class="mt-2 text-xs text-base-content/60 truncate pl-5"
            >
              {last_message_preview(log)}
            </div>
          </a>
        <% end %>
      </div>
    </div>
    """
  end

  # Per-request spend. Plan/subscription traffic bills nothing marginal, so
  # "$0" alone reads like missing data — show the would-have-cost instead.
  attr :log, :map, required: true

  defp log_cost(assigns) do
    actual = decimal_float(Map.get(assigns.log, :estimated_cost_usd))
    list = decimal_float(Map.get(assigns.log, :list_cost_usd))

    assigns =
      cond do
        actual > 0 -> assign(assigns, label: format_usd(actual), plan?: false)
        list > 0 -> assign(assigns, label: "~" <> format_usd(list), plan?: true)
        true -> assign(assigns, label: nil, plan?: false)
      end

    ~H"""
    <span
      :if={@label}
      class={["font-mono", @plan? && "text-base-content/35"]}
      title={@plan? && "Included in plan — cost at pay-as-you-go API rates"}
    >
      {@label}
    </span>
    """
  end

  # The pay-as-you-go figure, shown only when it exceeds what was actually
  # billed (i.e. some of the session ran on a plan/subscription key).
  defp would_be_cost(stats) do
    list = decimal_float(Map.get(stats, :total_list_cost_usd))

    if list > decimal_float(Map.get(stats, :total_cost_usd)), do: list
  end

  defp decimal_float(nil), do: 0.0
  defp decimal_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_float(n) when is_number(n), do: n / 1

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

  defp call_type_label("completion"), do: "chat"
  defp call_type_label("tool_call"), do: "tools"
  defp call_type_label("tool_enabled_completion"), do: "chat+tools"
  defp call_type_label(other), do: other

  defp status_badge_class("success"), do: "bg-success/20 text-success"
  defp status_badge_class("fallback"), do: "bg-warning/20 text-warning"
  defp status_badge_class("error"), do: "bg-error/20 text-error"
  defp status_badge_class("pending"), do: "bg-info/20 text-info"
  defp status_badge_class(_), do: "bg-base-300 text-base-content/60"

  defp last_message_preview(log) do
    if is_nil(Map.get(log, :request_body)) do
      nil
    else
      {messages, _} = MessageNormalizer.parse_request_body(log.request_body)

      messages
      |> Enum.reverse()
      |> Enum.find(fn msg ->
        msg.role in ~w(user assistant)
      end)
      |> case do
        nil -> nil
        %{content: content} when is_binary(content) and content != "" -> truncate_preview(content)
        %{reasoning_content: rc} when is_binary(rc) and rc != "" -> truncate_preview(rc)
        _ -> nil
      end
    end
  end

  defp truncate_preview(content) do
    if String.length(content) > 120 do
      String.slice(content, 0, 120) <> "..."
    else
      content
    end
  end

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")
end
