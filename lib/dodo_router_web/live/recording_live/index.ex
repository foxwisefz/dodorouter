defmodule DodoRouterWeb.RecordingLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Recordings
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
      |> assign(:page_title, "Recordings — #{router.slug}")
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
    recordings = Recordings.list_recordings(socket.assigns.router, limit: 50)
    {:noreply, assign(socket, :recordings, recordings)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Recordings</h1>
        <span class="text-sm text-base-content/60">{length(@recordings)} recordings</span>
      </div>

      <div class="space-y-3">
        <%= for recording <- @recordings do %>
          <a
            href={~p"/routers/#{@router.id}/recordings/#{recording.id}"}
            class="block bg-base-100 border border-base-300 rounded-xl p-4 hover:border-primary transition-colors"
          >
            <div class="flex items-center justify-between">
              <div>
                <div class="flex items-center gap-2">
                  <span class={[
                    "px-2 py-0.5 rounded text-xs font-medium",
                    if(recording.status == "recording",
                      do: "bg-success/20 text-success",
                      else: "bg-base-300/50 text-base-content/50"
                    )
                  ]}>
                    {recording.status}
                  </span>
                  <span
                    :if={recording.name}
                    class="font-medium text-base-content/90"
                  >
                    {recording.name}
                  </span>
                  <span :if={is_nil(recording.name)} class="font-mono text-sm text-base-content/50">
                    {recording.id}
                  </span>
                </div>
                <div class="text-sm text-base-content/60 mt-1">
                  {Calendar.strftime(recording.started_at, "%b %d, %H:%M")}
                  <%= if recording.stopped_at do %>
                    <span class="mx-1">→</span>
                    {Calendar.strftime(recording.stopped_at, "%b %d, %H:%M")}
                    <span class="ml-2 text-base-content/40">
                      ({format_duration(recording.started_at, recording.stopped_at)})
                    </span>
                  <% end %>
                </div>
              </div>
              <.link
                href={
                  ~p"/routers/#{@router.id}/recordings/#{recording.id}" <>
                    "?return_to=" <> URI.encode_www_form("/routers/#{@router.id}/recordings")
                }
                class="text-sm text-primary hover:underline"
              >
                View
              </.link>
            </div>
          </a>
        <% end %>

        <%= if Enum.empty?(@recordings) do %>
          <div class="text-center py-12 text-base-content/50">
            No recordings yet. Start one via the API: <pre class="mt-4 p-3 bg-base-200 rounded-lg text-left text-sm font-mono overflow-x-auto"><code phx-no-curly-interpolation>curl -X POST <%= @base_url %>/r/<%= @router.slug %>/recordings/start \
    -H "Authorization: Bearer YOUR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"name": "My Recording"}'</code></pre>
          </div>
        <% end %>
      </div>

      <%= if @page > 1 do %>
        <div class="flex justify-center mt-6 gap-2">
          <a
            href={~p"/routers/#{@router.id}/recordings?page=#{@page - 1}"}
            class="btn btn-sm btn-ghost"
          >
            Prev
          </a>
          <span class="btn btn-sm btn-disabled">Page {@page}</span>
          <a
            href={~p"/routers/#{@router.id}/recordings?page=#{@page + 1}"}
            class="btn btn-sm btn-ghost"
          >
            Next
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  defp apply_action(socket, params) do
    page =
      case Integer.parse(params["page"] || "1") do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    per_page = 20

    recordings =
      Recordings.list_recordings(socket.assigns.router,
        limit: per_page,
        offset: (page - 1) * per_page
      )

    socket
    |> assign(:recordings, recordings)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:base_url, DodoRouterWeb.Endpoint.url())
  end

  defp format_duration(started, stopped) do
    diff = DateTime.diff(stopped, started, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end
end
