defmodule DodoRouterWeb.RouterLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Routers
  alias DodoRouter.Routers.Router

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :routers, Routers.list_routers(socket.assigns.current_user))}
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
    socket =
      socket
      |> stream_insert(:routers, router, at: 0)
      |> assign(:show_api_key, api_key)

    {:noreply, socket}
  end

  def handle_info({DodoRouterWeb.RouterLive.FormComponent, {:saved, router}}, socket) do
    {:noreply, stream_insert(socket, :routers, router, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <h1 class="text-2xl font-bold">Routers</h1>
          <p class="text-base-content/60">Manage your API keys and routing configurations</p>
        </div>
        <.link patch={~p"/routers/new"} class="btn btn-primary">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Router
        </.link>
      </div>

      <!-- New API Key Alert -->
      <div :if={assigns[:show_api_key]} class="alert alert-warning mb-6">
        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
        <div class="flex-1">
          <h3 class="font-bold">Save your API key!</h3>
          <p class="text-sm">This won't be shown again.</p>
          <code class="block mt-2 p-3 bg-base-300 rounded font-mono text-sm break-all select-all">
            <%= @show_api_key %>
          </code>
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
      <div id="routers" phx-update="stream" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={{dom_id, router} <- @streams.routers} id={dom_id} class="card bg-base-100 shadow hover:shadow-lg transition-shadow">
          <div class="card-body">
            <div class="flex items-start justify-between">
              <div>
                <h2 class="card-title"><%= router.name %></h2>
                <p class="text-sm text-base-content/60 font-mono"><%= router.slug %></p>
              </div>
              <div class="dropdown dropdown-end">
                <label tabindex="0" class="btn btn-ghost btn-sm btn-square">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 5v.01M12 12v.01M12 19v.01M12 6a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2z" />
                  </svg>
                </label>
                <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow bg-base-200 rounded-box w-40">
                  <li><.link navigate={~p"/routers/#{router}"}>View</.link></li>
                  <li><.link navigate={~p"/routers/#{router}/routing"}>Routing</.link></li>
                  <li class="text-error">
                    <a phx-click="delete" phx-value-id={router.id} data-confirm="Delete this router?">
                      Delete
                    </a>
                  </li>
                </ul>
              </div>
            </div>

            <div class="mt-4 flex items-center gap-2">
              <div class="badge badge-ghost font-mono text-xs">
                <%= router.api_key_prefix %>...
              </div>
            </div>

            <div class="card-actions justify-end mt-4">
              <.link navigate={~p"/routers/#{router}"} class="btn btn-primary btn-sm">
                Open
              </.link>
            </div>
          </div>
        </div>
      </div>

      <!-- Empty State -->
      <div :if={Enum.empty?(@streams.routers.inserts)} class="hero min-h-[300px] bg-base-100 rounded-box">
        <div class="hero-content text-center">
          <div class="max-w-md">
            <h1 class="text-2xl font-bold">No routers yet</h1>
            <p class="py-4 text-base-content/60">
              Create your first router to get an API key and start routing requests.
            </p>
            <.link patch={~p"/routers/new"} class="btn btn-primary">Create Router</.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
