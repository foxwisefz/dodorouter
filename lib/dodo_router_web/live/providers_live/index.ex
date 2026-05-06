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
      |> assign(:form, nil)

    {:ok, socket}
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
      
    <!-- Provider Cards -->
      <div class="space-y-3">
        <%= for provider_slug <- ProviderKey.provider_slugs() do %>
          <% info = @provider_info[provider_slug] %>
          <% keys = Map.get(@provider_keys, provider_slug, []) %>
          <% key_count = length(keys) %>

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
                  <div class="flex items-center justify-between px-4 py-3 border-b border-base-300/20 last:border-b-0">
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
      </div>
    </div>
    """
  end

  defp provider_bg("emerald"), do: "bg-emerald-100"
  defp provider_bg("green"), do: "bg-green-100"
  defp provider_bg("amber"), do: "bg-amber-100"
  defp provider_bg("blue"), do: "bg-blue-100"
  defp provider_bg("purple"), do: "bg-purple-100"
  defp provider_bg("orange"), do: "bg-orange-100"
  defp provider_bg("cyan"), do: "bg-cyan-100"
  defp provider_bg("coral"), do: "bg-rose-100"
  defp provider_bg("slate"), do: "bg-slate-100"
  defp provider_bg(_), do: "bg-secondary"

  attr :slug, :string, required: true

  defp provider_logo(assigns) do
    ~H"""
    <%= case @slug do %>
      <% "openai" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M22.282 9.821a5.985 5.985 0 0 0-.516-4.91 6.046 6.046 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a5.985 5.985 0 0 0-3.998 2.9 6.046 6.046 0 0 0 .743 7.097 5.98 5.98 0 0 0 .51 4.911 6.051 6.051 0 0 0 6.515 2.9A5.985 5.985 0 0 0 13.26 24a6.056 6.056 0 0 0 5.772-4.206 5.99 5.99 0 0 0 3.997-2.9 6.056 6.056 0 0 0-.747-7.073zM13.26 22.43a4.476 4.476 0 0 1-2.876-1.04l.141-.081 4.779-2.758a.795.795 0 0 0 .392-.681v-6.737l2.02 1.168a.071.071 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.494 4.494zM3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085 4.783 2.759a.771.771 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646zM2.34 7.896a4.485 4.485 0 0 1 2.366-1.973V11.6a.766.766 0 0 0 .388.676l5.815 3.355-2.02 1.168a.076.076 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855l-5.833-3.387L15.119 7.2a.076.076 0 0 1 .071 0l4.83 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667zm2.01-3.023l-.141-.085-4.774-2.782a.776.776 0 0 0-.785 0L9.409 9.23V6.897a.066.066 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135l-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.795.795 0 0 0-.393.681zm1.097-2.365l2.602-1.5 2.607 1.5v2.999l-2.597 1.5-2.607-1.5z" />
        </svg>
      <% "anthropic" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M17.304 3h-2.437l5.378 18h2.466zM10.314 3H7.878l1.733 18h2.467zm-1.65 0H6.3L.854 21h2.604zm8.833 0h-2.364L13.5 21h2.604z" />
        </svg>
      <% "google" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z" />
          <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
          <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
          <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
        </svg>
      <% "groq" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <circle cx="12" cy="12" r="3" />
          <path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 2a8 8 0 0 1 5.66 13.66l-2.83-2.83A4 4 0 0 0 12 8a4 4 0 0 0-2.83 6.83l-2.83 2.83A8 8 0 0 1 12 4z" />
        </svg>
      <% "mistral" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <rect x="2" y="2" width="4" height="4" rx="1" />
          <rect x="7" y="2" width="4" height="4" rx="1" />
          <rect x="12" y="2" width="4" height="4" rx="1" />
          <rect x="18" y="2" width="4" height="4" rx="1" />
          <rect x="2" y="7" width="4" height="4" rx="1" />
          <rect x="7" y="7" width="4" height="4" rx="1" />
          <rect x="12" y="7" width="4" height="4" rx="1" />
          <rect x="18" y="7" width="4" height="4" rx="1" />
          <rect x="2" y="12" width="4" height="4" rx="1" />
          <rect x="7" y="12" width="4" height="4" rx="1" />
          <rect x="12" y="12" width="4" height="4" rx="1" />
          <rect x="18" y="12" width="4" height="4" rx="1" />
          <rect x="7" y="18" width="10" height="4" rx="1" />
        </svg>
      <% "xai" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M5.5 2L12 10l6.5-8h2.5L13 12l8 10h-2.5L12 14l-6.5 8H3l8-10L3 2h2.5z" />
        </svg>
      <% "deepseek" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm4.64 6.8c-.15 1.58-.8 5.42-1.13 7.19-.14.75-.42 1-.68 1.03-.58.05-1.02-.38-1.58-.75-.88-.58-1.38-.94-2.23-1.5-.99-.65-.35-1.01.22-1.59.15-.15 2.71-2.48 2.76-2.69a.2.2 0 0 0-.05-.18c-.06-.05-.14-.03-.21-.02-.09.02-1.49.95-4.22 2.79-.4.27-.76.41-1.08.4-.36-.01-1.04-.2-1.55-.37-.63-.2-1.12-.31-1.08-.66.02-.18.27-.36.74-.55 2.92-1.27 4.86-2.11 5.83-2.51 2.78-1.16 3.35-1.36 3.73-1.36.08 0 .27.02.39.12.1.08.13.19.14.27-.01.06.01.24 0 .38z" />
        </svg>
      <% "cohere" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 3.5c.97 0 1.87.25 2.66.69a6.39 6.39 0 0 1 2.08 1.87A8.75 8.75 0 0 1 18.68 12a8.75 8.75 0 0 1-1.94 3.94 6.39 6.39 0 0 1-2.08 1.87A6.23 6.23 0 0 1 12 18.5a6.23 6.23 0 0 1-2.66-.69 6.39 6.39 0 0 1-2.08-1.87A8.75 8.75 0 0 1 5.32 12a8.75 8.75 0 0 1 1.94-3.94A6.39 6.39 0 0 1 9.34 6.2 6.23 6.23 0 0 1 12 5.5zM12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z" />
        </svg>
      <% "moonshot" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M12 3a9 9 0 0 0 0 18c.83 0 1.5-.67 1.5-1.5 0-.39-.15-.74-.39-1.01-.23-.26-.38-.61-.38-1 0-.83.67-1.5 1.5-1.5H16c2.76 0 5-2.24 5-5 0-4.42-4.03-8-9-8zm-5.5 9a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm3-4A1.5 1.5 0 1 1 9.5 5 1.5 1.5 0 0 1 9.5 8zm5 0A1.5 1.5 0 1 1 14.5 5 1.5 1.5 0 0 1 14.5 8zm3 4a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3z" />
        </svg>
      <% "zai" -> %>
        <svg
          class="w-5 h-5"
          viewBox="0 0 24 24"
          fill="currentColor"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M12 2L2 7v10l10 5 10-5V7L12 2zm0 2.18L19.18 7.5 12 10.82 4.82 7.5 12 4.18zM4 8.93l7 3.5V19.5l-7-3.5V8.93zm9 10.57V12.43l7-3.5V15.5l-7 3.5z" />
        </svg>
      <% _ -> %>
        <.icon name="hero-server" class="size-4 text-base-content/50" />
    <% end %>
    """
  end

  defp next_label(existing_keys) do
    count = length(existing_keys) + 1
    "Key #{count}"
  end
end
