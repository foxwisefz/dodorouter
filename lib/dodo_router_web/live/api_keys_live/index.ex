defmodule DodoRouterWeb.ApiKeysLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Routers
  alias DodoRouter.Routers.ApiKey

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    routers = Routers.list_routers(scope.user)

    {:ok,
     socket
     |> assign(:page_title, "API Keys")
     |> assign(:base_url, DodoRouterWeb.Endpoint.url())
     |> assign(:router_usage, Logs.usage_summary_for_routers(Enum.map(routers, & &1.id)))
     |> assign(:new_key, nil)
     |> stream_configure(:routers, dom_id: &"router-#{&1.id}")
     |> stream(:routers, Enum.map(routers, &key_card(scope, &1)))}
  end

  @impl true
  def handle_event("create_key", %{"router_id" => id, "api_key" => attrs}, socket) do
    case Routers.create_api_key(socket.assigns.current_scope, id, attrs) do
      {:ok, key, secret} ->
        {:noreply,
         socket
         |> assign(:new_key, %{id: key.id, name: key.name, key: secret})
         |> refresh_router(id)
         |> put_flash(:info, "API key created")}

      {:error, changeset} ->
        {:noreply, refresh_router(socket, id, form: to_form(changeset, as: :api_key))}
    end
  end

  def handle_event("confirm_revoke", %{"router_id" => id, "key_id" => key_id}, socket) do
    {:noreply, refresh_router(socket, id, revoking_id: key_id)}
  end

  def handle_event("cancel_revoke", %{"router_id" => id}, socket) do
    {:noreply, refresh_router(socket, id)}
  end

  def handle_event("revoke_key", %{"router_id" => id, "key_id" => key_id}, socket) do
    case Routers.revoke_api_key(socket.assigns.current_scope, id, key_id) do
      {:ok, _key} ->
        socket =
          if socket.assigns.new_key && socket.assigns.new_key.id == key_id,
            do: assign(socket, :new_key, nil),
            else: socket

        {:noreply, socket |> refresh_router(id) |> put_flash(:info, "API key revoked")}

      {:error, :not_found} ->
        {:noreply,
         socket |> refresh_router(id) |> put_flash(:error, "API key is no longer active")}
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  defp refresh_router(socket, id, opts \\ []) do
    scope = socket.assigns.current_scope
    router = Routers.get_router!(scope.user, id)
    stream_insert(socket, :routers, key_card(scope, router, opts))
  end

  defp key_card(scope, router, opts \\ []) do
    %{
      id: router.id,
      name: router.name,
      slug: router.slug,
      keys: Routers.list_api_keys(scope, router.id),
      revoking_id: Keyword.get(opts, :revoking_id),
      form:
        Keyword.get_lazy(opts, :form, fn ->
          to_form(ApiKey.changeset(%ApiKey{}, %{}), as: :api_key)
        end)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-3xl">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-base-content">API Keys</h1>
          <p class="text-base-content/50 text-sm mt-1">
            Give each client its own key. Add and revoke keys independently for each router.
          </p>
        </div>

        <div
          :if={@new_key}
          id="new-api-key"
          class="mb-6 rounded-xl border border-accent/20 bg-accent/5 p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-semibold text-accent mb-1">New API key: {@new_key.name}</p>
              <p class="text-xs text-base-content/60 mb-2">Copy this now — you won't see it again.</p>
              <div class="flex items-center gap-2">
                <code class="min-w-0 flex-1 break-all rounded-lg bg-base-100 border border-base-300/50 px-3 py-2 text-sm font-mono">
                  {@new_key.key}
                </code>
                <button
                  id="copy-new-api-key"
                  phx-hook="CopyButton"
                  data-copy={@new_key.key}
                  class="btn btn-sm btn-ghost"
                  title="Copy API key"
                >
                  <.icon name="hero-clipboard" class="size-4" />
                </button>
              </div>
            </div>
            <button
              id="dismiss-api-key"
              phx-click="dismiss_key"
              class="btn btn-sm btn-ghost"
              aria-label="Dismiss API key"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <div id="router-keys" phx-update="stream" class="space-y-4">
          <div id="no-router-keys" class="hidden only:block text-center py-12">
            <.icon name="hero-key" class="size-8 text-base-content/30 mb-3" />
            <p class="text-sm text-base-content/50">No routers yet</p>
            <.link navigate={~p"/routers/new"} class="text-sm text-accent hover:underline">
              Create your first router
            </.link>
          </div>
          <section
            :for={{dom_id, router} <- @streams.routers}
            id={dom_id}
            class="rounded-xl border border-base-300/50 bg-base-100 p-5"
          >
            <div class="flex items-center justify-between gap-3">
              <h2 class="font-semibold">{router.name}</h2>
              <.link navigate={~p"/routers/#{router.id}"} class="text-xs text-accent hover:underline">
                View router
              </.link>
            </div>
            <div class="flex items-center gap-2 mt-2 min-w-0">
              <code
                id={"endpoint-#{router.id}"}
                class="font-mono text-xs text-base-content/60 truncate"
              >
                {@base_url}/r/{router.slug}/v1/chat/completions
              </code>
              <button
                id={"copy-endpoint-#{router.id}"}
                phx-hook="CopyButton"
                data-copy={"#{@base_url}/r/#{router.slug}/v1/chat/completions"}
                class="btn btn-xs btn-ghost"
                title="Copy endpoint"
              >
                <.icon name="hero-clipboard" class="size-3" />
              </button>
            </div>
            <.router_usage_note usage={Map.get(@router_usage, router.id)} />

            <div class="mt-4 divide-y divide-base-300/50">
              <p
                :if={router.keys == []}
                id={"no-keys-#{router.id}"}
                class="py-3 text-sm text-base-content/60"
              >
                No active keys. Create a key to connect a client.
              </p>
              <div
                :for={key <- router.keys}
                id={"api-key-#{key.id}"}
                class="py-3 flex flex-wrap items-center justify-between gap-3"
              >
                <div>
                  <p class="text-sm font-medium">{key.name}</p>
                  <p class="text-xs text-base-content/50 mt-1">
                    <code>{key.api_key_prefix}•••••••</code>
                    <span class="ml-2">
                      Created {Calendar.strftime(key.inserted_at, "%b %d, %Y")}
                    </span>
                  </p>
                </div>
                <%= if router.revoking_id == key.id do %>
                  <div class="w-full rounded-lg bg-error/5 p-3">
                    <p class="text-xs text-base-content/70 mb-2">
                      Clients using this key will stop working immediately. Other keys stay active.
                    </p>
                    <button
                      id={"confirm-revoke-#{key.id}"}
                      phx-click="revoke_key"
                      phx-value-router_id={router.id}
                      phx-value-key_id={key.id}
                      class="btn btn-sm btn-error"
                    >
                      Revoke key
                    </button>
                    <button
                      id={"cancel-revoke-#{key.id}"}
                      phx-click="cancel_revoke"
                      phx-value-router_id={router.id}
                      class="btn btn-sm btn-ghost"
                    >
                      Cancel
                    </button>
                  </div>
                <% else %>
                  <button
                    id={"revoke-key-#{key.id}"}
                    phx-click="confirm_revoke"
                    phx-value-router_id={router.id}
                    phx-value-key_id={key.id}
                    class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                  >
                    Revoke
                  </button>
                <% end %>
              </div>
            </div>
            <.form
              for={router.form}
              id={"create-key-#{router.id}"}
              phx-submit="create_key"
              phx-value-router_id={router.id}
              class="mt-4 pt-4 border-t border-base-300/50 flex flex-col sm:flex-row sm:items-end gap-3"
            >
              <div class="flex-1">
                <.input
                  field={router.form[:name]}
                  id={"key-name-#{router.id}"}
                  label="Key name"
                  placeholder="e.g. Production server"
                  required
                  maxlength="100"
                />
              </div>
              <button type="submit" class="btn btn-primary btn-sm mb-2" phx-disable-with="Creating…">
                <.icon name="hero-plus" class="size-4" /> Create key
              </button>
            </.form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :usage, :map, default: nil

  defp router_usage_note(assigns) do
    ~H"""
    <p
      class="text-xs text-base-content/40 mt-1"
      data-router-requests-24h={(@usage && @usage.request_count_24h) || 0}
    >
      Router activity:
      <%= if @usage && @usage.last_request_at do %>
        last used {relative_time(@usage.last_request_at)} · {pluralize(
          @usage.request_count_24h,
          "request"
        )} in the last 24h across all keys
      <% else %>
        never used
      <% end %>
    </p>
    """
  end

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
