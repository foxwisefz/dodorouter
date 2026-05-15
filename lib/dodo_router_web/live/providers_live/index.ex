defmodule DodoRouterWeb.ProvidersLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Providers
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy.Adapter.Registry

  @impl true
  def mount(_params, _session, socket) do
    provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Providers")
      |> assign(:provider_keys, provider_keys)
      |> assign(:provider_info, Registry.provider_info())
      |> assign(:adding_to, nil)
      |> assign(:editing_key, nil)
      |> assign(:highlighted_key_id, nil)
      |> assign(:filtered_provider, nil)
      |> assign(:form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:highlighted_key_id, params["highlight"])
      |> assign(:filtered_provider, params["provider"])

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_provider", %{"provider" => provider_slug}, socket) do
    {:noreply, assign(socket, :filtered_provider, provider_slug)}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, assign(socket, :filtered_provider, nil)}
  end

  @impl true
  def handle_event("start_add", %{"provider" => provider_slug}, socket) do
    changeset = ProviderKey.changeset(%ProviderKey{}, %{provider_slug: provider_slug})
    form = to_form(changeset)

    {:noreply, assign(socket, adding_to: provider_slug, form: form)}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, adding_to: nil, form: nil)}
  end

  def handle_event("start_edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_key: id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_key: nil)}
  end

  def handle_event("save_label", %{"key_id" => id, "label" => label}, socket) do
    provider_key = Providers.get_provider_key!(socket.assigns.current_user, id)

    case Providers.update_provider_key(provider_key, %{label: label}) do
      {:ok, _updated} ->
        provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

        socket =
          socket
          |> assign(:provider_keys, provider_keys)
          |> assign(:editing_key, nil)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update label")}
    end
  end

  def handle_event("validate", %{"provider_key" => params}, socket) do
    changeset =
      %ProviderKey{}
      |> ProviderKey.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"provider_key" => params}, socket) do
    api_key = params["api_key"] || ""

    if String.trim(api_key) == "" do
      socket = put_flash(socket, :error, "Please enter an API key")
      {:noreply, socket}
    else
      provider_slug = socket.assigns.adding_to
      existing_keys = Map.get(socket.assigns.provider_keys, provider_slug, [])

      label =
        case params["label"] do
          nil -> next_label(existing_keys)
          "" -> next_label(existing_keys)
          l -> l
        end

      attrs = %{
        provider_slug: provider_slug,
        label: label
      }

      case Providers.create_provider_key(socket.assigns.current_user, attrs, api_key) do
        {:ok, _provider_key} ->
          provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

          socket =
            socket
            |> assign(:provider_keys, provider_keys)
            |> assign(:adding_to, nil)
            |> assign(:form, nil)
            |> put_flash(:info, "API key added")

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          error_msg =
            case changeset.errors do
              [{:label, _} | _] -> "A key with that label already exists"
              _ -> "Failed to save API key"
            end

          socket = put_flash(socket, :error, error_msg)
          {:noreply, socket}

        {:error, {:secret_storage_failed, _reason}} ->
          socket = put_flash(socket, :error, "Failed to store API key securely")
          {:noreply, socket}

        {:error, _other} ->
          socket = put_flash(socket, :error, "Something went wrong")
          {:noreply, socket}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    provider_key = Providers.get_provider_key!(socket.assigns.current_user, id)
    {:ok, _} = Providers.delete_provider_key(provider_key)

    provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

    socket =
      socket
      |> assign(:provider_keys, provider_keys)
      |> put_flash(:info, "API key removed")

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl">
      <!-- Header -->
      <div class="mb-8">
        <h1 class="text-2xl font-bold">Providers</h1>
        <p class="text-base-content/50 text-sm">Connect your LLM provider API keys</p>
      </div>
      
    <!-- Provider Filter -->
      <div class="flex items-center gap-2 mb-4 flex-wrap">
        <button
          type="button"
          phx-click="clear_filter"
          class={[
            "px-3 py-1.5 text-xs font-medium rounded-lg transition",
            is_nil(@filtered_provider) && "bg-primary text-primary-content",
            not is_nil(@filtered_provider) && "bg-base-200 text-base-content hover:bg-base-300"
          ]}
        >
          All
        </button>
        <%= for provider_slug <- ProviderKey.provider_slugs() do %>
          <% info = @provider_info[provider_slug] %>
          <button
            type="button"
            phx-click="filter_provider"
            phx-value-provider={provider_slug}
            class={[
              "px-3 py-1.5 text-xs font-medium rounded-lg transition",
              @filtered_provider == provider_slug && "bg-primary text-primary-content",
              @filtered_provider != provider_slug && "bg-base-200 text-base-content hover:bg-base-300"
            ]}
          >
            {info.name}
          </button>
        <% end %>
      </div>
      
    <!-- Provider Cards -->
      <div class="space-y-3">
        <%= for provider_slug <- ProviderKey.provider_slugs() do %>
          <% info = @provider_info[provider_slug] %>
          <% keys = Map.get(@provider_keys, provider_slug, []) %>
          <% key_count = length(keys) %>
          <% show_card = is_nil(@filtered_provider) || @filtered_provider == provider_slug %>
          <%= if show_card do %>
            <div class="card-bordered overflow-hidden">
              <!-- Provider Header -->
              <div class="p-4 flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <div class={[
                    "w-8 h-8 rounded-lg flex items-center justify-center shrink-0",
                    provider_bg(info.color)
                  ]}>
                    <.provider_logo slug={provider_slug} />
                  </div>
                  <div>
                    <h2 class="font-semibold">{info.name}</h2>
                    <p class="text-xs text-base-content/50">{info.short}</p>
                  </div>
                </div>
                <div class="flex items-center gap-3">
                  <%= if key_count > 0 do %>
                    <span class="text-xs text-base-content/50">
                      {key_count} {if key_count == 1, do: "key", else: "keys"}
                    </span>
                  <% end %>
                  <%= if @adding_to != provider_slug do %>
                    <button
                      phx-click="start_add"
                      phx-value-provider={provider_slug}
                      class="btn btn-sm btn-primary"
                    >
                      Add Key
                    </button>
                  <% end %>
                </div>
              </div>
              
    <!-- Keys List -->
              <%= if key_count > 0 || @adding_to == provider_slug do %>
                <div class="border-t border-base-300/40 bg-base-200/30">
                  <!-- Existing Keys -->
                  <%= for key <- keys do %>
                    <div
                      id={"key-#{key.id}"}
                      class={[
                        "flex items-center justify-between px-4 py-3 border-b border-base-300/20 last:border-b-0",
                        @highlighted_key_id == key.id && "bg-primary/10 border-l-2 border-primary"
                      ]}
                      phx-hook={@highlighted_key_id == key.id && "ScrollIntoView"}
                    >
                      <%= if @editing_key == key.id do %>
                        <form phx-submit="save_label" class="flex items-center gap-2 flex-1">
                          <input type="hidden" name="key_id" value={key.id} />
                          <input
                            type="text"
                            name="label"
                            value={key.label}
                            class="flex-1 px-2 py-1 bg-base-100 border border-base-300/50 rounded text-sm focus:outline-none focus:border-primary/50"
                            autofocus
                          />
                          <button type="submit" class="text-primary hover:text-primary/80 p-1">
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
                                d="M5 13l4 4L19 7"
                              />
                            </svg>
                          </button>
                          <button
                            type="button"
                            phx-click="cancel_edit"
                            class="text-base-content/40 hover:text-base-content p-1"
                          >
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
                                d="M6 18L18 6M6 6l12 12"
                              />
                            </svg>
                          </button>
                        </form>
                      <% else %>
                        <div class="flex items-center gap-3">
                          <svg
                            xmlns="http://www.w3.org/2000/svg"
                            class="h-4 w-4 text-success"
                            fill="none"
                            viewBox="0 0 24 24"
                            stroke="currentColor"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              stroke-width="2"
                              d="M5 13l4 4L19 7"
                            />
                          </svg>
                          <button
                            phx-click="start_edit"
                            phx-value-id={key.id}
                            class="text-sm hover:text-primary transition-colors"
                          >
                            {key.label}
                            <span class="text-base-content/40 font-mono text-xs ml-1.5">
                              {key.key_hint}
                            </span>
                          </button>
                        </div>
                        <button
                          phx-click="delete"
                          phx-value-id={key.id}
                          data-confirm="Remove this API key?"
                          class="text-base-content/40 hover:text-error transition-colors p-1"
                        >
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
                              d="M6 18L18 6M6 6l12 12"
                            />
                          </svg>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                  
    <!-- Add Key Form -->
                  <%= if @adding_to == provider_slug do %>
                    <.form
                      for={@form}
                      phx-submit="save"
                      class="px-4 py-3"
                      autocomplete="off"
                      data-1p-ignore
                      data-lpignore="true"
                    >
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name="provider_key[api_key]"
                          placeholder="Paste your API key here..."
                          class="flex-1 px-3 py-2 bg-base-100 border border-base-300/50 rounded-lg text-sm font-mono focus:outline-none focus:border-primary/50"
                          autocomplete="off"
                          data-1p-ignore
                          data-lpignore="true"
                          spellcheck="false"
                          autofocus
                        />
                        <button type="submit" class="btn btn-sm btn-primary">Save</button>
                        <button type="button" phx-click="cancel_add" class="btn btn-sm btn-ghost">
                          Cancel
                        </button>
                      </div>
                    </.form>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp next_label(existing_keys) do
    count = length(existing_keys) + 1
    "Key #{count}"
  end
end
