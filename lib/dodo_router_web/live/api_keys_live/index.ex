defmodule DodoRouterWeb.ApiKeysLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Routers

  @impl true
  def mount(_params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)
    base_url = DodoRouterWeb.Endpoint.url()

    socket =
      socket
      |> assign(:page_title, "API Keys")
      |> assign(:routers, routers)
      |> assign(:base_url, base_url)
      |> assign(:regenerating_id, nil)
      |> assign(:new_key, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("regenerate", %{"id" => id}, socket) do
    router = Routers.get_router!(socket.assigns.current_user, id)

    case Routers.regenerate_api_key(router) do
      {:ok, _router, api_key} ->
        routers =
          socket.assigns.current_user
          |> Routers.list_routers()

        {:noreply,
         socket
         |> assign(:routers, routers)
         |> assign(:new_key, %{router_id: id, key: api_key})
         |> assign(:regenerating_id, nil)
         |> put_flash(:info, "API key regenerated for #{router.name}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate API key")}
    end
  end

  def handle_event("confirm_regenerate", %{"id" => id}, socket) do
    {:noreply, assign(socket, :regenerating_id, id)}
  end

  def handle_event("cancel_regenerate", _params, socket) do
    {:noreply, assign(socket, :regenerating_id, nil)}
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl">
      <div class="mb-8">
        <h1 class="text-2xl font-bold text-base-content">API Keys</h1>
        <p class="text-base-content/50 text-sm mt-1">
          Manage your router API keys. Use these keys to authenticate with the proxy.
        </p>
      </div>

      <%!-- New Key Banner --%>
      <div
        :if={@new_key}
        class="mb-6 rounded-xl border border-accent/20 bg-accent/5 p-4"
      >
        <div class="flex items-start justify-between">
          <div class="flex-1">
            <p class="text-sm font-semibold text-accent mb-1">
              New API Key Generated
            </p>
            <p class="text-xs text-base-content/50 mb-2">
              Copy this now — you won't see it again.
            </p>
            <div class="flex items-center gap-2">
              <code class="flex-1 rounded-lg bg-base-100 border border-base-300/50 px-3 py-2 text-sm font-mono text-base-content">
                {@new_key.key}
              </code>
              <button
                phx-click={JS.dispatch("phx:copy", to: "#api-key-#{@new_key.router_id}")}
                class="p-2 rounded-lg bg-base-100 border border-base-300/50 hover:bg-secondary transition-colors"
                title="Copy"
              >
                <.icon name="hero-clipboard" class="size-4 text-base-content/60" />
              </button>
            </div>
          </div>
          <button
            phx-click="dismiss_key"
            class="p-1 rounded hover:bg-base-200 text-base-content/40 hover:text-base-content transition-colors"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- Router Keys List --%>
      <div class="space-y-3">
        <%= for router <- @routers do %>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-accent/10 text-accent">
                  <.icon name="hero-adjustments-horizontal" class="size-4" />
                </div>
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="text-sm font-semibold text-base-content">{router.name}</h3>
                    <.link
                      navigate={~p"/routers/#{router.id}"}
                      class="text-xs text-accent hover:underline"
                    >
                      View router
                    </.link>
                  </div>
                  <div class="flex items-center gap-1.5 mt-0.5">
                    <p class="text-xs text-base-content/40 shrink-0">Endpoint:</p>
                    <code
                      id={"endpoint-#{router.id}"}
                      class="font-mono text-xs text-base-content/60 truncate"
                    >
                      {@base_url}/r/{router.slug}/v1/chat/completions
                    </code>
                    <button
                      phx-click={JS.dispatch("phx:copy", to: "#endpoint-#{router.id}")}
                      class="p-1 rounded hover:bg-base-200 text-base-content/40 hover:text-base-content/60 transition-colors shrink-0"
                      title="Copy endpoint"
                    >
                      <.icon name="hero-clipboard" class="size-3" />
                    </button>
                  </div>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    Existing key:
                    <code class="font-mono text-base-content/60">{router.api_key_prefix}•••••••</code>
                  </p>
                </div>
              </div>

              <%= if @regenerating_id == router.id do %>
                <div class="flex items-center gap-2">
                  <span class="text-xs text-base-content/50">Are you sure?</span>
                  <button
                    phx-click="regenerate"
                    phx-value-id={router.id}
                    class="px-3 py-1.5 rounded-lg bg-error text-white text-xs font-medium hover:opacity-90 transition-opacity"
                  >
                    Yes, revoke
                  </button>
                  <button
                    phx-click="cancel_regenerate"
                    class="px-3 py-1.5 rounded-lg bg-secondary text-base-content/70 text-xs font-medium hover:bg-secondary/80 transition-colors"
                  >
                    Cancel
                  </button>
                </div>
              <% else %>
                <button
                  phx-click="confirm_regenerate"
                  phx-value-id={router.id}
                  class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-base-300/50 text-xs font-medium text-base-content/60 hover:text-error hover:border-error/30 hover:bg-error/5 transition-colors"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" /> Regenerate
                </button>
              <% end %>
            </div>
          </div>
        <% end %>

        <div :if={Enum.empty?(@routers)} class="text-center py-12">
          <div class="w-12 h-12 mx-auto mb-4 rounded-xl bg-secondary flex items-center justify-center">
            <.icon name="hero-key" class="size-6 text-base-content/30" />
          </div>
          <p class="text-sm text-base-content/50">No routers yet</p>
          <a href={~p"/routers/new"} class="text-sm text-accent hover:underline mt-1 inline-block">
            Create your first router
          </a>
        </div>
      </div>
    </div>
    """
  end
end
