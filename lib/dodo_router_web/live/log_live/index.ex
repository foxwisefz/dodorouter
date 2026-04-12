defmodule DodoRouterWeb.LogLive.Index do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.{Logs, Routers}

  @impl true
  def mount(_params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Request Logs")
      |> assign(:routers, routers)
      |> assign(:selected_router_id, nil)
      |> assign(:selected_router, nil)
      |> assign(:subscribed_all, false)
      |> stream(:logs, [])

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:subscribed_all] do
      unsubscribe_all_routers(socket)
    else
      if socket.assigns.selected_router_id do
        Logs.unsubscribe_from_logs(socket.assigns.selected_router_id)
      end
    end

    :ok
  end

  @impl true
  def handle_params(params, _url, socket) do
    router_id = params["router_id"]
    old_router_id = socket.assigns.selected_router_id
    was_all = old_router_id == nil && socket.assigns[:subscribed_all]

    # Unsubscribe from previous subscriptions
    if connected?(socket) do
      if was_all do
        unsubscribe_all_routers(socket)
      else
        if old_router_id && old_router_id != router_id do
          Logs.unsubscribe_from_logs(old_router_id)
        end
      end
    end

    socket =
      if router_id do
        router = Routers.get_router!(socket.assigns.current_user, router_id)
        logs = Logs.list_logs(router, limit: 100)

        # Subscribe to this router
        if connected?(socket) && old_router_id != router_id do
          Logs.subscribe_to_logs(router_id)
        end

        socket
        |> assign(:selected_router_id, router_id)
        |> assign(:selected_router, router)
        |> assign(:subscribed_all, false)
        |> stream(:logs, logs, reset: true)
      else
        # Show all logs across all routers
        logs = Logs.list_logs_for_user(socket.assigns.current_user, limit: 100)

        # Subscribe to all routers
        if connected?(socket) && !was_all do
          subscribe_all_routers(socket)
        end

        socket
        |> assign(:selected_router_id, nil)
        |> assign(:selected_router, nil)
        |> assign(:subscribed_all, true)
        |> stream(:logs, logs, reset: true)
      end

    {:noreply, socket}
  end

  defp subscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.subscribe_to_logs(router.id)
    end)
  end

  defp unsubscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.unsubscribe_from_logs(router.id)
    end)
  end

  @impl true
  def handle_info({:log_pending, pending}, socket) do
    # Use request_id as stream key so completed log replaces it in place
    pending = Map.put(pending, :id, pending.request_id)
    {:noreply, stream_insert(socket, :logs, pending, at: 0)}
  end

  def handle_info({:log_created, log}, socket) do
    # Use request_id as key to replace pending entry in place
    log = Map.put(log, :id, log.request_id)
    {:noreply, stream_insert(socket, :logs, log)}
  end

  @impl true
  def handle_event("select_router", params, socket) do
    Logger.debug("select_router params: #{inspect(params)}")

    case params do
      %{"router_id" => ""} ->
        {:noreply, push_patch(socket, to: ~p"/logs")}

      %{"router_id" => router_id} ->
        {:noreply, push_patch(socket, to: ~p"/logs?router_id=#{router_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
        <div>
          <h1 class="text-2xl font-bold">Request Logs</h1>
          <p class="text-base-content/50 text-sm">API request history</p>
        </div>
        <form phx-change="select_router">
          <select
            name="router_id"
            class="py-2 px-3 bg-base-200 border border-base-300/50 rounded-lg text-sm w-full sm:w-48"
          >
            <option value="">All routers</option>
            <option
              :for={r <- @routers}
              value={r.id}
              selected={to_string(r.id) == @selected_router_id}
            >
              {r.name}
            </option>
          </select>
        </form>
      </div>
      
    <!-- Logs Table -->
      <div class="table-container">
        <table class="table">
          <thead>
            <tr>
              <th>Time</th>
              <th :if={!@selected_router}>Router</th>
              <th>Status</th>
              <th>Provider/Model</th>
              <th>Type</th>
              <th>Tokens</th>
              <th>Latency</th>
              <th>Attempts</th>
            </tr>
          </thead>
          <tbody id="logs" phx-update="stream">
            <tr
              :for={{dom_id, log} <- @streams.logs}
              id={dom_id}
              phx-click={log.status != "pending" && JS.navigate(~p"/logs/#{log}")}
              class={[
                "hover:bg-base-200/30 transition-colors",
                log.status == "pending" && "animate-pulse",
                log.status != "pending" && "cursor-pointer"
              ]}
            >
              <td class="font-mono text-xs text-base-content/70">{format_time(log.inserted_at)}</td>
              <td :if={!@selected_router} class="text-sm">
                <.link
                  :if={Map.get(log, :router)}
                  navigate={~p"/routers/#{log.router}"}
                  class="text-primary hover:underline"
                >
                  {log.router.name}
                </.link>
              </td>
              <td><.status_badge status={log.status} /></td>
              <td>
                <%= if is_list(Map.get(log, :attempted_steps)) and length(log.attempted_steps) > 1 do %>
                  <div class="flex items-center gap-1">
                    <%= for {step, idx} <- Enum.with_index(log.attempted_steps) do %>
                      <span class={[
                        "text-xs px-1.5 py-0.5 rounded",
                        step["status"] == "success" && "bg-success/20 text-success",
                        step["status"] != "success" && "bg-error/20 text-error line-through"
                      ]}>
                        {step["provider"]}
                      </span>
                      <%= if idx < length(log.attempted_steps) - 1 do %>
                        <span class="text-base-content/30">→</span>
                      <% end %>
                    <% end %>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">{log.final_model}</div>
                <% else %>
                  <span class="text-base-content/80">{log.final_provider}</span>
                  <span class="text-base-content/40"> / </span>
                  <span class="text-base-content/60">{log.final_model}</span>
                <% end %>
              </td>
              <td><.call_type_badge type={Map.get(log, :call_type)} /></td>
              <td class="font-mono text-sm text-base-content/70">
                {Map.get(log, :total_tokens) || "-"}
              </td>
              <td class="font-mono text-sm text-base-content/70">
                {if Map.get(log, :latency_ms), do: "#{log.latency_ms}ms", else: "-"}
              </td>
              <td class="text-center">
                <%= if is_list(Map.get(log, :attempted_steps)) and length(log.attempted_steps) > 1 do %>
                  <span class="px-1.5 py-0.5 bg-warning/20 text-warning rounded text-xs">
                    {length(log.attempted_steps)}
                  </span>
                <% else %>
                  <span class="text-base-content/40">
                    {if log.status == "pending", do: "-", else: "1"}
                  </span>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "bg-success/20 text-success"
        "fallback" -> "bg-warning/20 text-warning"
        "error" -> "bg-error/20 text-error"
        "pending" -> "bg-info/20 text-info"
        _ -> "bg-base-300 text-base-content/60"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}>{@status}</span>
    """
  end

  defp call_type_badge(assigns) do
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool", "bg-secondary/20 text-secondary"}
        "tool_enabled_completion" -> {"Tool+", "bg-primary/20 text-primary"}
        _ -> {"Chat", "bg-base-300 text-base-content/60"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}>{@label}</span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
