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
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <h1 class="text-2xl font-bold">Request Logs</h1>
          <p class="text-base-content/60">Browse and filter API request history</p>
        </div>
        <form phx-change="select_router">
          <select
            name="router_id"
            class="select select-bordered w-full sm:w-auto"
          >
            <option value="">Select a router...</option>
            <option :for={r <- @routers} value={r.id} selected={to_string(r.id) == @selected_router_id}>
              <%= r.name %>
            </option>
          </select>
        </form>
      </div>

      <!-- Filters -->
      <div :if={@selected_router} class="card bg-base-100 shadow mb-6">
        <div class="card-body py-4">
          <div class="flex flex-wrap gap-4 items-center">
            <span class="text-sm font-medium">Filters:</span>

            <select phx-change="filter" name="status" class="select select-bordered select-sm">
              <option value="">All Status</option>
              <option value="success" selected={@filters.status == "success"}>Success</option>
              <option value="fallback" selected={@filters.status == "fallback"}>Fallback</option>
              <option value="error" selected={@filters.status == "error"}>Error</option>
            </select>

            <select phx-change="filter" name="call_type" class="select select-bordered select-sm">
              <option value="">All Types</option>
              <option value="completion" selected={@filters.call_type == "completion"}>Completion</option>
              <option value="tool_call" selected={@filters.call_type == "tool_call"}>Tool Call</option>
              <option value="tool_enabled_completion" selected={@filters.call_type == "tool_enabled_completion"}>Tool Enabled</option>
            </select>
          </div>
        </div>
      </div>

      <!-- Logs Table -->
      <div :if={@selected_router} class="card bg-base-100 shadow">
        <div class="card-body p-0">
          <div class="overflow-x-auto">
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
                <tr :for={{dom_id, log} <- @streams.logs} id={dom_id} class="hover">
                  <td class="font-mono text-xs"><%= format_time(log.inserted_at) %></td>
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
                            <span class="text-base-content/40">→</span>
                          <% end %>
                        <% end %>
                      </div>
                      <div class="text-xs text-base-content/60 mt-0.5"><%= log.final_model %></div>
                    <% else %>
                      <span class="font-medium"><%= log.final_provider %></span>
                      <span class="text-base-content/60">/ <%= log.final_model %></span>
                    <% end %>
                  </td>
                  <td><.call_type_badge type={log.call_type} /></td>
                  <td class="font-mono text-sm"><%= log.total_tokens || "-" %></td>
                  <td class="font-mono text-sm"><%= if log.latency_ms, do: "#{log.latency_ms}ms", else: "-" %></td>
                  <td class="text-center">
                    <%= if length(log.attempted_steps) > 1 do %>
                      <span class="badge badge-warning badge-sm"><%= length(log.attempted_steps) %></span>
                    <% else %>
                      <span class="text-base-content/50">1</span>
                    <% end %>
                  </td>
                  <td>
                    <.link navigate={~p"/logs/#{log}"} class="btn btn-ghost btn-xs">
                      View
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <!-- Empty State -->
      <div :if={!@selected_router} class="hero min-h-[300px] bg-base-100 rounded-box">
        <div class="hero-content text-center">
          <div class="max-w-md">
            <h1 class="text-2xl font-bold">Select a Router</h1>
            <p class="py-4 text-base-content/60">
              Choose a router from the dropdown above to view its request logs.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "badge-success"
        "fallback" -> "badge-warning"
        "error" -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"badge badge-sm #{@class}"}><%= @status %></span>
    """
  end

  defp call_type_badge(assigns) do
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool", "badge-secondary"}
        "tool_enabled_completion" -> {"Tool+", "badge-primary"}
        _ -> {"Chat", "badge-ghost"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={"badge badge-sm #{@class}"}><%= @label %></span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
