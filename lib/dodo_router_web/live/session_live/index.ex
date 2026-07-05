defmodule DodoRouterWeb.SessionLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Routers

  @impl true
  def mount(%{"router_id" => router_id} = params, _socket_session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:logs")
    end

    socket =
      socket
      |> assign(:router, router)
      |> assign(:page_title, "Sessions — #{router.slug}")
      |> apply_action(params)

    {:ok, socket}
  end

  def mount(_params, _socket_session, socket) do
    {:ok, redirect(socket, to: ~p"/routers")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, params)}
  end

  @impl true
  def handle_info({:log_created, _log}, socket) do
    # Refresh sessions list when new logs come in
    sessions = Logs.list_sessions(socket.assigns.router, limit: 50)
    {:noreply, assign(socket, :sessions, sessions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Sessions</h1>
        <span class="text-sm text-base-content/60">{pluralize(length(@sessions), "session")}</span>
      </div>

      <div class="space-y-3">
        <%= for session <- @sessions do %>
          <a
            href={~p"/routers/#{@router.id}/sessions/#{session.session_id}"}
            class="block bg-base-100 border border-base-300 rounded-xl p-4 hover:border-primary transition-colors"
          >
            <div class="flex items-center justify-between">
              <div>
                <div class="font-mono text-sm text-primary">
                  {session.session_id}
                </div>
                <%= if session.session_name do %>
                  <div class="text-sm text-base-content/70 mt-1">
                    {session.session_name}
                  </div>
                <% end %>
              </div>
              <div class="text-right text-sm text-base-content/60">
                <div>{pluralize(session.request_count, "request")}</div>
                <div>{Calendar.strftime(session.last_activity, "%b %d, %H:%M")}</div>
              </div>
            </div>
          </a>
        <% end %>

        <%= if Enum.empty?(@sessions) do %>
          <div class="text-center py-12 text-base-content/50">
            No sessions yet. Send requests with an
            <code class="bg-base-200 px-1 rounded">X-Session-Id</code>
            header to create one.
          </div>
        <% end %>
      </div>

      <%= if @page > 1 do %>
        <div class="flex justify-center mt-6 gap-2">
          <a href={~p"/routers/#{@router.id}/sessions?page=#{@page - 1}"} class="btn btn-sm btn-ghost">
            ← Prev
          </a>
          <span class="btn btn-sm btn-disabled">Page {@page}</span>
          <a href={~p"/routers/#{@router.id}/sessions?page=#{@page + 1}"} class="btn btn-sm btn-ghost">
            Next →
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  defp apply_action(socket, params) do
    page = String.to_integer(params["page"] || "1")
    per_page = 20

    sessions =
      Logs.list_sessions(socket.assigns.router,
        limit: per_page,
        offset: (page - 1) * per_page
      )

    socket
    |> assign(:sessions, sessions)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
  end
end
