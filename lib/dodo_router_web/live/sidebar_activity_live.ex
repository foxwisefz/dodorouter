defmodule DodoRouterWeb.SidebarActivityLive do
  @moduledoc """
  LiveView for the sidebar router list with real-time activity indicators.

  Shows per-router in-flight request counts with color-coded badges:
  - Green: requests on primary provider
  - Orange: requests that fell back to secondary providers
  """

  use DodoRouterWeb, :live_view

  alias DodoRouter.Routers
  alias DodoRouter.Activity
  alias DodoRouter.Logs

  @impl true
  def mount(_params, session, socket) do
    user_id = session["user_id"]
    current_path = session["current_path"] || ""

    if is_nil(user_id) do
      {:ok,
       assign(socket,
         routers: [],
         activity: %{},
         total_active: 0,
         requests: %{},
         current_path: current_path
       )}
    else
      user = %DodoRouter.Accounts.User{id: user_id}
      routers = Routers.list_routers_with_step_count(user)
      router_ids = Enum.map(routers, & &1.id)

      # Read initial activity state from Agent
      activity = Activity.get_routers_counts(router_ids)
      total_active = Activity.get_total_active(router_ids)

      # Subscribe to all router topics for live updates
      Enum.each(routers, fn router ->
        Logs.subscribe_to_logs(router.id)
        Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
      end)

      socket =
        socket
        |> assign(:routers, routers)
        |> assign(:activity, activity)
        |> assign(:total_active, total_active)
        # request_id => {router_id, status}
        |> assign(:requests, %{})
        |> assign(:current_path, current_path)

      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mt-5 sidebar-section">
      <div class="flex items-center justify-between mb-1.5 px-3">
        <p class="sidebar-label text-xs font-semibold uppercase tracking-wider text-base-content/40">
          Routers
        </p>
        <%= if @total_active > 0 do %>
          <span class="flex items-center gap-1.5 text-[10px] font-semibold text-success animate-fade-in">
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-success"></span>
            </span>
            {@total_active}
          </span>
        <% end %>
      </div>

      <%= if length(@routers) > 0 do %>
        <%= for router <- @routers do %>
          <% {primary, fallback} = Map.get(@activity, router.id, {0, 0}) %>

          <.link
            navigate={~p"/routers/#{router.id}"}
            title={router.name}
            class="sidebar-item flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors group text-base-content/60 hover:bg-secondary"
          >
            <span class={[
              "flex h-5 w-5 items-center justify-center rounded text-xs font-bold shrink-0",
              router.color == "blue" && "bg-blue-100 text-blue-700",
              router.color == "purple" && "bg-purple-100 text-purple-700",
              router.color == "amber" && "bg-amber-100 text-amber-700",
              router.color == "rose" && "bg-rose-100 text-rose-700",
              router.color == "emerald" && "bg-emerald-100 text-emerald-700",
              router.color == "sky" && "bg-sky-100 text-sky-700",
              router.color == "orange" && "bg-orange-100 text-orange-700",
              router.color == "indigo" && "bg-indigo-100 text-indigo-700"
            ]}>
              {String.upcase(String.first(router.name))}
            </span>
            <span class="sidebar-label truncate">{router.name}</span>

            <div class="sidebar-label ml-auto flex items-center gap-1 transition-all duration-300">
              <%= if primary > 0 do %>
                <span class="activity-badge bg-success text-success-content">
                  {primary}
                </span>
              <% end %>
              <%= if fallback > 0 do %>
                <span class="activity-badge bg-warning text-warning-content">
                  {fallback}
                </span>
              <% end %>
            </div>
          </.link>
        <% end %>
      <% else %>
        <p class="sidebar-label px-3 py-2 text-xs text-base-content/40">No routers yet</p>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_info({:log_pending, pending}, socket) do
    router_id = pending.router_id || pending.router.id
    request_id = pending.request_id

    requests = Map.put(socket.assigns.requests, request_id, {router_id, :primary})
    activity = update_activity_count(socket.assigns.activity, router_id, :primary, +1)
    total_active = socket.assigns.total_active + 1

    {:noreply,
     socket
     |> assign(:requests, requests)
     |> assign(:activity, activity)
     |> assign(:total_active, total_active)}
  end

  @impl true
  def handle_info(
        {:step_started, %{request_id: request_id, router_id: router_id, step_index: step_index}},
        socket
      )
      when step_index > 0 do
    requests = socket.assigns.requests

    case Map.get(requests, request_id) do
      {^router_id, :primary} ->
        new_requests = Map.put(requests, request_id, {router_id, :fallback})

        activity =
          socket.assigns.activity
          |> update_activity_count(router_id, :primary, -1)
          |> update_activity_count(router_id, :fallback, +1)

        {:noreply,
         socket
         |> assign(:requests, new_requests)
         |> assign(:activity, activity)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:step_started, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:proxy_event, %{request_id: request_id, router_id: router_id}}, socket) do
    remove_request(socket, request_id, router_id)
  end

  @impl true
  def handle_info({:log_created, log}, socket) do
    router_id = log.router_id
    request_id = log.request_id
    remove_request(socket, request_id, router_id)
  end

  @impl true
  def handle_info({:step_completed, _}, socket) do
    {:noreply, socket}
  end

  defp remove_request(socket, request_id, router_id) do
    requests = socket.assigns.requests

    case Map.pop(requests, request_id) do
      {{^router_id, status}, new_requests} ->
        activity = update_activity_count(socket.assigns.activity, router_id, status, -1)
        total_active = max(0, socket.assigns.total_active - 1)

        {:noreply,
         socket
         |> assign(:requests, new_requests)
         |> assign(:activity, activity)
         |> assign(:total_active, total_active)}

      _ ->
        # Request not tracked locally (e.g., after reconnect/hot upgrade).
        # Re-sync activity counts from Activity to avoid stale UI.
        activity = Activity.get_routers_counts(socket.assigns.routers |> Enum.map(& &1.id))
        total_active = Activity.get_total_active(socket.assigns.routers |> Enum.map(& &1.id))

        {:noreply,
         socket
         |> assign(:activity, activity)
         |> assign(:total_active, total_active)}
    end
  end

  defp update_activity_count(activity, router_id, status, delta) do
    {primary, fallback} = Map.get(activity, router_id, {0, 0})

    new_counts =
      case status do
        :primary -> {max(0, primary + delta), fallback}
        :fallback -> {primary, max(0, fallback + delta)}
        _ -> {primary, fallback}
      end

    Map.put(activity, router_id, new_counts)
  end
end
