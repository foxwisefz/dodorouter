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
      |> assign(:filters, %{status: nil, provider: nil, call_type: nil})
      |> stream(:logs, [])

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.selected_router_id do
      Logs.unsubscribe_from_logs(socket.assigns.selected_router_id)
    end

    :ok
  end

  @impl true
  def handle_params(params, _url, socket) do
    router_id = params["router_id"]
    old_router_id = socket.assigns.selected_router_id

    # Unsubscribe from old router if switching
    if old_router_id && old_router_id != router_id do
      Logs.unsubscribe_from_logs(old_router_id)
    end

    socket =
      if router_id do
        router = Routers.get_router!(socket.assigns.current_user, router_id)
        logs = Logs.list_logs(router, limit: 100)

        # Subscribe to new logs for this router
        if connected?(socket) && old_router_id != router_id do
          Logs.subscribe_to_logs(router_id)
        end

        socket
        |> assign(:selected_router_id, router_id)
        |> assign(:selected_router, router)
        |> stream(:logs, logs, reset: true)
      else
        socket
        |> assign(:selected_router_id, nil)
        |> assign(:selected_router, nil)
        |> stream(:logs, [], reset: true)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:log_created, log}, socket) do
    # Insert new log at the top of the stream
    {:noreply, stream_insert(socket, :logs, log, at: 0)}
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

  def handle_event("filter", %{"status" => status}, socket) do
    filters = %{socket.assigns.filters | status: if(status == "", do: nil, else: status)}
    {:noreply, reload_logs(socket, filters)}
  end

  def handle_event("filter", %{"provider" => provider}, socket) do
    filters = %{socket.assigns.filters | provider: if(provider == "", do: nil, else: provider)}
    {:noreply, reload_logs(socket, filters)}
  end

  def handle_event("filter", %{"call_type" => call_type}, socket) do
    filters = %{socket.assigns.filters | call_type: if(call_type == "", do: nil, else: call_type)}
    {:noreply, reload_logs(socket, filters)}
  end

  defp reload_logs(socket, filters) do
    if socket.assigns.selected_router do
      logs = Logs.list_logs(socket.assigns.selected_router, Map.to_list(filters) ++ [limit: 100])

      socket
      |> assign(:filters, filters)
      |> stream(:logs, logs, reset: true)
    else
      assign(socket, :filters, filters)
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
          <p class="text-base-content/50 text-sm">Browse and filter API request history</p>
        </div>
        <form phx-change="select_router">
          <select
            name="router_id"
            class="py-2 px-3 bg-base-200 border border-base-300/50 rounded-lg text-sm w-full sm:w-48"
          >
            <option value="">Select a router...</option>
            <option :for={r <- @routers} value={r.id} selected={to_string(r.id) == @selected_router_id}>
              <%= r.name %>
            </option>
          </select>
        </form>
      </div>

      <!-- Filters -->
      <div :if={@selected_router} class="card-bordered p-4 mb-6">
        <div class="flex flex-wrap gap-3 items-center">
          <span class="text-sm font-medium text-base-content/60">Filters:</span>

          <select phx-change="filter" name="status" class="py-1.5 px-2 bg-base-200 border border-base-300/50 rounded-lg text-sm">
            <option value="">All Status</option>
            <option value="success" selected={@filters.status == "success"}>Success</option>
            <option value="fallback" selected={@filters.status == "fallback"}>Fallback</option>
            <option value="error" selected={@filters.status == "error"}>Error</option>
          </select>

          <select phx-change="filter" name="call_type" class="py-1.5 px-2 bg-base-200 border border-base-300/50 rounded-lg text-sm">
            <option value="">All Types</option>
            <option value="completion" selected={@filters.call_type == "completion"}>Completion</option>
            <option value="tool_call" selected={@filters.call_type == "tool_call"}>Tool Call</option>
            <option value="tool_enabled_completion" selected={@filters.call_type == "tool_enabled_completion"}>Tool Enabled</option>
          </select>
        </div>
      </div>

      <!-- Logs Table -->
      <div :if={@selected_router} class="table-container">
        <table class="table">
          <thead>
            <tr>
              <th>Time</th>
              <th>Status</th>
              <th>Provider/Model</th>
              <th>Type</th>
              <th>Tokens</th>
              <th>Latency</th>
              <th>Attempts</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="logs" phx-update="stream">
            <tr :for={{dom_id, log} <- @streams.logs} id={dom_id} class="hover:bg-base-200/30">
              <td class="font-mono text-xs text-base-content/70"><%= format_time(log.inserted_at) %></td>
              <td><.status_badge status={log.status} /></td>
              <td>
                <%= if length(log.attempted_steps) > 1 do %>
                  <div class="flex items-center gap-1">
                    <%= for {step, idx} <- Enum.with_index(log.attempted_steps) do %>
                      <span class={[
                        "text-xs px-1.5 py-0.5 rounded",
                        step["status"] == "success" && "bg-success/20 text-success",
                        step["status"] != "success" && "bg-error/20 text-error line-through"
                      ]}>
                        <%= step["provider"] %>
                      </span>
                      <%= if idx < length(log.attempted_steps) - 1 do %>
                        <span class="text-base-content/30">→</span>
                      <% end %>
                    <% end %>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5"><%= log.final_model %></div>
                <% else %>
                  <span class="text-base-content/80"><%= log.final_provider %></span>
                  <span class="text-base-content/40"> / </span>
                  <span class="text-base-content/60"><%= log.final_model %></span>
                <% end %>
              </td>
              <td><.call_type_badge type={log.call_type} /></td>
              <td class="font-mono text-sm text-base-content/70"><%= log.total_tokens || "-" %></td>
              <td class="font-mono text-sm text-base-content/70"><%= if log.latency_ms, do: "#{log.latency_ms}ms", else: "-" %></td>
              <td class="text-center">
                <%= if length(log.attempted_steps) > 1 do %>
                  <span class="px-1.5 py-0.5 bg-warning/20 text-warning rounded text-xs"><%= length(log.attempted_steps) %></span>
                <% else %>
                  <span class="text-base-content/40">1</span>
                <% end %>
              </td>
              <td>
                <.link navigate={~p"/logs/#{log}"} class="text-sm text-primary hover:underline">
                  View
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Empty State -->
      <div :if={!@selected_router} class="card-bordered p-12 text-center">
        <div class="max-w-md mx-auto">
          <div class="stat-icon w-16 h-16 mx-auto mb-6">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-8 w-8" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
            </svg>
          </div>
          <h2 class="text-xl font-semibold mb-2">Select a Router</h2>
          <p class="text-base-content/50">
            Choose a router from the dropdown above to view its request logs.
          </p>
        </div>
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
        _ -> "bg-base-300 text-base-content/60"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}><%= @status %></span>
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
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}><%= @label %></span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
