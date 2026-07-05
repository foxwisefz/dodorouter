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
         current_path: current_path
       )}
    else
      user = %DodoRouter.Accounts.User{id: user_id}
      routers = Routers.list_routers_with_step_count(user)
      router_ids = Enum.map(routers, & &1.id)

      # Read initial activity state from Activity (source of truth)
      activity = Activity.get_routers_counts(router_ids)
      total_active = Activity.get_total_active(router_ids)

      # Subscribe to all router topics for live updates
      Enum.each(routers, fn router ->
        Logs.subscribe_to_logs(router.id)
        Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
      end)

      # Stay in sync when routers are created, renamed, or deleted
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, Routers.user_routers_topic(user_id))

      socket =
        socket
        |> assign(:user_id, user_id)
        |> assign(:routers, routers)
        |> assign(:activity, activity)
        |> assign(:total_active, total_active)
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
  def handle_info({:log_pending, _pending}, socket) do
    {:noreply, refresh_activity(socket)}
  end

  @impl true
  def handle_info({:step_started, _}, socket) do
    {:noreply, refresh_activity(socket)}
  end

  @impl true
  def handle_info({:proxy_event, _}, socket) do
    {:noreply, refresh_activity(socket)}
  end

  @impl true
  def handle_info({:log_created, _}, socket) do
    {:noreply, refresh_activity(socket)}
  end

  @impl true
  def handle_info({:step_completed, _}, socket) do
    {:noreply, refresh_activity(socket)}
  end

  @impl true
  def handle_info({event, router}, socket)
      when event in [:router_created, :router_updated, :router_deleted] do
    user = %DodoRouter.Accounts.User{id: socket.assigns.user_id}
    routers = Routers.list_routers_with_step_count(user)

    if event == :router_created do
      Logs.subscribe_to_logs(router.id)
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
    end

    {:noreply, socket |> assign(:routers, routers) |> refresh_activity()}
  end

  # Refresh activity counts from Activity (source of truth).
  # Called on every event to ensure we never go out of sync.
  defp refresh_activity(socket) do
    router_ids = Enum.map(socket.assigns.routers, & &1.id)
    activity = Activity.get_routers_counts(router_ids)
    total_active = Activity.get_total_active(router_ids)

    socket
    |> assign(:activity, activity)
    |> assign(:total_active, total_active)
  end
end
