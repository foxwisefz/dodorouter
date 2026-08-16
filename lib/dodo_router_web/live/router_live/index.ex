defmodule DodoRouterWeb.RouterLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Routers
  alias DodoRouter.Routers.Router

  @impl true
  def mount(_params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    socket =
      socket
      |> assign(:activity, Logs.activity_summary_for_routers(Enum.map(routers, & &1.id)))
      |> stream(:routers, routers)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Router")
    |> assign(:router, %Router{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Routers")
    |> assign(:router, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    router = Routers.get_router!(socket.assigns.current_user, id)
    {:ok, _} = Routers.delete_router(router)

    {:noreply, stream_delete(socket, :routers, router)}
  end

  @impl true
  def handle_info({DodoRouterWeb.RouterLive.FormComponent, {:saved, router, api_key}}, socket) do
    # Send the user straight into their new router; the one-time key is
    # carried in the flash and rendered by the show page's key banner.
    {:noreply,
     socket
     |> put_flash(:new_api_key, api_key)
     |> push_navigate(to: ~p"/routers/#{router}")}
  end

  def handle_info({DodoRouterWeb.RouterLive.FormComponent, {:saved, router}}, socket) do
    {:noreply, stream_insert(socket, :routers, router, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <!-- Header -->
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
          <div>
            <h1 class="text-2xl font-bold">Routers</h1>
            <p class="text-base-content/50 text-sm">
              Manage your API keys and routing configurations
            </p>
          </div>
          <.link patch={~p"/routers/new"} class="btn btn-primary gap-2">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            New Router
          </.link>
        </div>
        
    <!-- New API Key Alert -->
        <div :if={assigns[:show_api_key]} class="card-bordered mb-6 border-warning/50 bg-warning/5">
          <div class="flex gap-3">
            <div class="stat-icon bg-warning/10 text-warning flex-shrink-0">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
            </div>
            <div class="flex-1">
              <h3 class="font-semibold text-warning">Save your API key!</h3>
              <p class="text-sm text-base-content/60">This won't be shown again.</p>
              <div class="flex items-start gap-2 mt-2">
                <code class="flex-1 p-3 bg-base-300 rounded-lg font-mono text-sm break-all select-all">
                  {@show_api_key}
                </code>
                <button
                  id="copy-new-api-key"
                  phx-hook="CopyButton"
                  data-copy={@show_api_key}
                  class="p-3 rounded-lg bg-base-300 hover:bg-base-content/10 transition-colors shrink-0"
                  title="Copy API key"
                >
                  <.icon name="hero-clipboard" class="size-4 text-base-content/60" />
                </button>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Modal -->
        <.modal :if={@live_action == :new} id="router-modal" show on_cancel={JS.patch(~p"/routers")}>
          <.live_component
            module={DodoRouterWeb.RouterLive.FormComponent}
            id={@router.id || :new}
            title={@page_title}
            action={@live_action}
            router={@router}
            current_user={@current_user}
            patch={~p"/routers"}
          />
        </.modal>
        
    <!-- Routers Grid -->
        <div
          id="routers"
          phx-update="stream"
          class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          <div
            :for={{dom_id, router} <- @streams.routers}
            id={dom_id}
            class="card-bordered hover:bg-base-200/30 transition-colors"
          >
            <div class="flex items-start justify-between mb-4">
              <div>
                <h2 class="text-lg font-semibold">{router.name}</h2>
                <p class="text-sm text-base-content/50 font-mono">{router.slug}</p>
              </div>
              <div class="dropdown dropdown-end">
                <label
                  tabindex="0"
                  class="p-2 rounded-lg hover:bg-base-200 cursor-pointer text-base-content/50 hover:text-base-content transition-colors"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-5 w-5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 5v.01M12 12v.01M12 19v.01M12 6a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2z"
                    />
                  </svg>
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] p-2 shadow-lg bg-base-100 border border-base-300/50 rounded-xl w-40"
                >
                  <li>
                    <.link
                      navigate={~p"/routers/#{router}"}
                      class="block px-3 py-2 rounded-lg hover:bg-base-200 text-sm"
                    >
                      View
                    </.link>
                  </li>
                  <li>
                    <.link
                      navigate={~p"/routers/#{router}/routing"}
                      class="block px-3 py-2 rounded-lg hover:bg-base-200 text-sm"
                    >
                      Routing
                    </.link>
                  </li>
                  <li>
                    <a
                      phx-click="delete"
                      phx-value-id={router.id}
                      data-confirm="Delete this router?"
                      class="block px-3 py-2 rounded-lg hover:bg-error/10 text-error text-sm"
                    >
                      Delete
                    </a>
                  </li>
                </ul>
              </div>
            </div>

            <div class="flex items-center gap-2 mb-4">
              <span class="px-2 py-1 bg-base-200 rounded text-xs font-mono text-base-content/60">
                {router.api_key_prefix}...
              </span>
            </div>

            <.router_activity activity={Map.get(@activity, router.id)} />

            <div class="flex justify-end">
              <.link navigate={~p"/routers/#{router}"} class="btn btn-primary btn-sm">
                Open
              </.link>
            </div>
          </div>
        </div>
        
    <!-- Empty State -->
        <div :if={Enum.empty?(@streams.routers.inserts)} class="card-bordered text-center">
          <div class="max-w-md mx-auto">
            <div class="stat-icon w-16 h-16 mx-auto mb-6">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-8 w-8"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2"
                />
              </svg>
            </div>
            <h2 class="text-xl font-semibold mb-2">No routers yet</h2>
            <p class="text-base-content/50 mb-6">
              Create your first router to get an API key and start routing requests.
            </p>
            <.link patch={~p"/routers/new"} class="btn btn-primary">Create Router</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # A router serving 40k req/day and one never called used to render
  # identically — request count, error rate and an hourly sparkline for the
  # same 24h window, ambient rather than a dashboard (dodo_router-f6v.4).
  attr :activity, :map, default: nil

  defp router_activity(assigns) do
    ~H"""
    <div
      :if={@activity && @activity.request_count > 0}
      class="flex items-center gap-2 mb-4 text-xs text-base-content/50"
      data-router-requests={@activity.request_count}
      data-router-errors={@activity.error_count}
    >
      {sparkline_svg(@activity.hourly)}
      <span>{@activity.request_count} req · last 24h</span>
      <span :if={@activity.error_count > 0} class="text-error font-medium">
        {error_rate_pct(@activity)}% errors
      </span>
    </div>
    <div
      :if={!@activity || @activity.request_count == 0}
      class="mb-4 text-xs text-base-content/30"
      data-router-requests="0"
      data-router-errors="0"
    >
      No requests in the last 24h
    </div>
    """
  end

  defp error_rate_pct(%{request_count: 0}), do: 0

  defp error_rate_pct(%{request_count: total, error_count: errors}),
    do: round(errors / total * 100)

  # A tiny inline polyline — no chart library needed for 24 points.
  defp sparkline_svg(hourly) do
    max = Enum.max([1 | hourly])
    width = 60
    height = 16
    step = if length(hourly) > 1, do: width / (length(hourly) - 1), else: 0

    points =
      hourly
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = Float.round(i * step, 1)
        y = Float.round(height - v / max * height, 1)
        "#{x},#{y}"
      end)

    assigns = %{points: points, width: width, height: height}

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} width={@width} height={@height} class="shrink-0">
      <polyline
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        class="text-primary/60"
      />
    </svg>
    """
  end
end
