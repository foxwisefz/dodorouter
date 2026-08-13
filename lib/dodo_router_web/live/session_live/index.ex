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

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign_cache_verdicts(sessions)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <div class="flex items-center justify-between mb-6">
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/routers/#{@router.id}"}
              class="btn btn-ghost btn-sm btn-circle"
              title={"Back to #{@router.name}"}
            >
              ←
            </.link>
            <div>
              <h1 class="text-2xl font-bold">Sessions</h1>
              <p class="text-sm text-base-content/50">{@router.name}</p>
            </div>
          </div>
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
                  <div
                    :if={regressed?(@cache_verdicts, session)}
                    class="flex items-center gap-1.5 mt-1.5 text-xs font-medium text-warning"
                    title="The cached prefix stopped hitting partway through this session — open it to see where."
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3.5" /> Cache stopped hitting
                  </div>
                </div>
                <div class="text-right text-sm text-base-content/60">
                  <div>{pluralize(session.request_count, "request")}</div>
                  <.session_cost session={session} />
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
            <a
              href={~p"/routers/#{@router.id}/sessions?page=#{@page - 1}"}
              class="btn btn-sm btn-ghost"
            >
              ← Prev
            </a>
            <span class="btn btn-sm btn-disabled">Page {@page}</span>
            <a
              href={~p"/routers/#{@router.id}/sessions?page=#{@page + 1}"}
              class="btn btn-sm btn-ghost"
            >
              Next →
            </a>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Actual spend, plus the pay-as-you-go figure whenever it is higher — that
  # gap is the part of the session served by plan/subscription keys, which
  # bill nothing marginal and would otherwise just show "$0".
  attr :session, :map, required: true

  defp session_cost(assigns) do
    actual = decimal_float(assigns.session.total_cost_usd)
    list = decimal_float(assigns.session.total_list_cost_usd)

    assigns =
      assign(assigns,
        actual: if(actual > 0, do: format_usd(actual)),
        would_be: if(list > actual, do: format_usd(list))
      )

    ~H"""
    <div :if={@actual || @would_be} class="font-mono text-base-content/80">
      {@actual}
      <span
        :if={@would_be}
        class="text-base-content/40"
        title="Traffic served through subscription/coding-plan keys has no marginal per-token cost. This is what the same tokens would cost at pay-as-you-go API list prices."
      >
        {if @actual, do: "· "}~{@would_be} at API rates
      </span>
    </div>
    """
  end

  defp decimal_float(nil), do: 0.0
  defp decimal_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_float(n) when is_number(n), do: n / 1

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
    |> assign_cache_verdicts(sessions)
  end

  defp assign_cache_verdicts(socket, sessions) do
    verdicts =
      Logs.cache_verdicts(socket.assigns.router, Enum.map(sessions, & &1.session_id))

    assign(socket, :cache_verdicts, verdicts)
  end

  defp regressed?(verdicts, session) do
    match?({:regressed, _}, Map.get(verdicts, session.session_id))
  end
end
