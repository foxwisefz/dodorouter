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

    active_recording = Recordings.get_active_recording(router)

    socket =
      socket
      |> assign(:router, router)
      |> assign(:page_title, "Recordings — #{router.slug}")
      |> assign(:active_recording, active_recording)
      |> assign(:show_start_form, false)
      |> assign(:recording_name, "")
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
  def handle_event("toggle_start_form", _params, socket) do
    {:noreply, assign(socket, :show_start_form, !socket.assigns.show_start_form)}
  end

  def handle_event("start_recording", %{"recording" => %{"name" => name}}, socket) do
    name = if name == "", do: nil, else: name

    case Recordings.start_recording(socket.assigns.router, %{name: name}) do
      {:ok, recording} ->
        recordings = Recordings.list_recordings(socket.assigns.router, limit: 50)

        {:noreply,
         socket
         |> assign(:active_recording, recording)
         |> assign(:recordings, recordings)
         |> assign(:show_start_form, false)
         |> assign(:recording_name, "")
         |> put_flash(:info, "Recording started")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to start recording")}
    end
  end

  def handle_event("stop_recording", _params, socket) do
    case Recordings.stop_recording(socket.assigns.router) do
      {:ok, _recording} ->
        recordings = Recordings.list_recordings(socket.assigns.router, limit: 50)

        {:noreply,
         socket
         |> assign(:active_recording, nil)
         |> assign(:recordings, recordings)
         |> put_flash(:info, "Recording stopped")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:active_recording, nil)
         |> put_flash(:error, "No active recording")}
    end
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
        <div class="flex items-center gap-3">
          <span class="text-sm text-base-content/60">{pluralize(length(@recordings), "recording")}</span>
          <%= if @active_recording do %>
            <button
              phx-click="stop_recording"
              class="btn btn-sm btn-error gap-2"
            >
              <span class="w-2 h-2 rounded-full bg-error-content animate-pulse"></span> Stop Recording
            </button>
          <% else %>
            <button
              phx-click="toggle_start_form"
              class="btn btn-sm btn-primary gap-2"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="currentColor"
                viewBox="0 0 24 24"
              >
                <circle cx="12" cy="12" r="8" />
              </svg>
              Start Recording
            </button>
          <% end %>
        </div>
      </div>
      
    <!-- Start Recording Form -->
      <div :if={@show_start_form} class="card-bordered p-4 mb-6 bg-primary/5 border-primary/30">
        <form phx-submit="start_recording" class="flex items-end gap-3">
          <div class="flex-1">
            <label class="block text-sm font-medium text-base-content/70 mb-1">
              Recording Name (optional)
            </label>
            <input
              type="text"
              name="recording[name]"
              value={@recording_name}
              placeholder="e.g., debug-session-1"
              class="w-full py-2 px-3 bg-base-100 border border-base-300 rounded-lg"
              autofocus
            />
          </div>
          <button type="submit" class="btn btn-primary">Start</button>
          <button type="button" phx-click="toggle_start_form" class="btn btn-ghost">Cancel</button>
        </form>
      </div>
      
    <!-- Active Recording Banner -->
      <div :if={@active_recording} class="card-bordered p-4 mb-6 bg-success/10 border-success/30">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <span class="w-3 h-3 rounded-full bg-success animate-pulse"></span>
            <div>
              <span class="font-medium">Recording in progress</span>
              <span :if={@active_recording.name} class="text-base-content/70 ml-2">
                — {@active_recording.name}
              </span>
            </div>
          </div>
          <div class="text-sm text-base-content/60">
            Started {Calendar.strftime(@active_recording.started_at, "%H:%M:%S")}
          </div>
        </div>
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
            No recordings yet. Click "Start Recording" above to begin capturing requests.
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
