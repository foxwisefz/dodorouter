defmodule DodoRouterWeb.LogLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.{Logs, Projects}

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_projects(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Request Logs")
      |> assign(:projects, projects)
      |> assign(:selected_project_id, nil)
      |> assign(:filters, %{status: nil, provider: nil, call_type: nil})
      |> assign(:logs, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_id = params["project_id"]

    socket =
      if project_id do
        project = Projects.get_project!(socket.assigns.current_user, project_id)
        logs = Logs.list_logs(project, limit: 100)

        socket
        |> assign(:selected_project_id, project_id)
        |> assign(:selected_project, project)
        |> stream(:logs, logs, reset: true)
      else
        socket
        |> assign(:selected_project_id, nil)
        |> assign(:selected_project, nil)
        |> stream(:logs, [], reset: true)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_project", %{"project_id" => project_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/logs?project_id=#{project_id}")}
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
    if socket.assigns.selected_project do
      logs = Logs.list_logs(socket.assigns.selected_project, Map.to_list(filters) ++ [limit: 100])

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
    <div class="max-w-7xl mx-auto">
      <.header>
        Request Logs
      </.header>

      <div class="mt-6 flex gap-4 items-end">
        <div>
          <label class="block text-sm font-medium text-gray-700">Project</label>
          <select phx-change="select_project" name="project_id" class="mt-1 rounded-md border-gray-300">
            <option value="">Select a project...</option>
            <option :for={p <- @projects} value={p.id} selected={to_string(p.id) == @selected_project_id}>
              <%= p.name %>
            </option>
          </select>
        </div>

        <div :if={@selected_project}>
          <label class="block text-sm font-medium text-gray-700">Status</label>
          <select phx-change="filter" name="status" class="mt-1 rounded-md border-gray-300">
            <option value="">All</option>
            <option value="success" selected={@filters.status == "success"}>Success</option>
            <option value="fallback" selected={@filters.status == "fallback"}>Fallback</option>
            <option value="error" selected={@filters.status == "error"}>Error</option>
          </select>
        </div>

        <div :if={@selected_project}>
          <label class="block text-sm font-medium text-gray-700">Call Type</label>
          <select phx-change="filter" name="call_type" class="mt-1 rounded-md border-gray-300">
            <option value="">All</option>
            <option value="completion" selected={@filters.call_type == "completion"}>Completion</option>
            <option value="tool_call" selected={@filters.call_type == "tool_call"}>Tool Call</option>
            <option value="tool_enabled_completion" selected={@filters.call_type == "tool_enabled_completion"}>Tool Enabled</option>
          </select>
        </div>
      </div>

      <div :if={@selected_project} class="mt-6">
        <.table id="logs" rows={@streams.logs} row_click={fn {_id, log} -> JS.navigate(~p"/logs/#{log}") end}>
          <:col :let={{_id, log}} label="Time">
            <span class="font-mono text-xs"><%= format_time(log.inserted_at) %></span>
          </:col>
          <:col :let={{_id, log}} label="Status">
            <.status_badge status={log.status} />
          </:col>
          <:col :let={{_id, log}} label="Provider/Model">
            <span class="font-medium"><%= log.final_provider %></span>
            <span class="text-gray-500">/ <%= log.final_model %></span>
          </:col>
          <:col :let={{_id, log}} label="Type">
            <.call_type_badge type={log.call_type} />
          </:col>
          <:col :let={{_id, log}} label="Tokens">
            <%= log.total_tokens || "-" %>
          </:col>
          <:col :let={{_id, log}} label="Latency">
            <%= if log.latency_ms, do: "#{log.latency_ms}ms", else: "-" %>
          </:col>
          <:col :let={{_id, log}} label="Attempts">
            <%= length(log.attempted_steps) %>
          </:col>
        </.table>
      </div>

      <div :if={!@selected_project} class="mt-12 text-center text-gray-500">
        Select a project to view its request logs.
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "bg-green-100 text-green-800"
        "fallback" -> "bg-yellow-100 text-yellow-800"
        "error" -> "bg-red-100 text-red-800"
        _ -> "bg-gray-100 text-gray-800"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}><%= @status %></span>
    """
  end

  defp call_type_badge(assigns) do
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool", "bg-purple-100 text-purple-800"}
        "tool_enabled_completion" -> {"Tool+", "bg-blue-100 text-blue-800"}
        _ -> {"Chat", "bg-gray-100 text-gray-800"}
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
