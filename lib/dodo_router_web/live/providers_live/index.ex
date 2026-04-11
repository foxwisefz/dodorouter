defmodule DodoRouterWeb.ProvidersLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Providers
  alias DodoRouter.Providers.ProviderKey

  @provider_info %{
    "zai_standard" => %{name: "z.ai (Standard Plan)", endpoint: "https://api.z.ai/api/paas/v4"},
    "zai_coding" => %{name: "z.ai (Coding Plan)", endpoint: "https://api.z.ai/api/coding/paas/v4"},
    "moonshot" => %{name: "Moonshot (Kimi)", endpoint: "https://api.moonshot.ai/v1"}
  }

  @impl true
  def mount(_params, _session, socket) do
    provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Providers")
      |> assign(:provider_keys, provider_keys)
      |> assign(:provider_info, @provider_info)
      |> assign(:adding_to, nil)
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
      changeset =
        %ProviderKey{}
        |> ProviderKey.changeset(params)
        |> Ecto.Changeset.add_error(:api_key, "can't be blank")
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, form: to_form(changeset))}
    else
      attrs = %{
        provider_slug: socket.assigns.adding_to,
        label: params["label"]
      }

      case Providers.create_provider_key(socket.assigns.current_user, attrs, api_key) do
        {:ok, _provider_key} ->
          provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

          socket =
            socket
            |> assign(:provider_keys, provider_keys)
            |> assign(:adding_to, nil)
            |> assign(:form, nil)
            |> put_flash(:info, "API key added successfully")

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}

        {:error, {:secret_storage_failed, reason}} ->
          socket = put_flash(socket, :error, "Failed to store API key: #{inspect(reason)}")
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
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <h1 class="text-2xl font-bold">Providers</h1>
          <p class="text-base-content/60">Manage API keys for LLM providers</p>
        </div>
      </div>

      <!-- Provider Cards -->
      <div class="space-y-6">
        <%= for provider_slug <- ProviderKey.provider_slugs() do %>
          <% info = @provider_info[provider_slug] %>
          <% keys = Map.get(@provider_keys, provider_slug, []) %>

          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <!-- Provider Header -->
              <div class="flex items-center justify-between">
                <div>
                  <h2 class="card-title"><%= info.name %></h2>
                  <p class="text-sm text-base-content/60 font-mono"><%= info.endpoint %></p>
                </div>
              </div>

              <!-- Existing Keys -->
              <div class="mt-4 space-y-2">
                <%= for key <- keys do %>
                  <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                    <div class="flex items-center gap-3">
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 text-success" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
                      </svg>
                      <span class="font-medium"><%= key.label %></span>
                    </div>
                    <button
                      phx-click="delete"
                      phx-value-id={key.id}
                      data-confirm="Remove this API key?"
                      class="btn btn-ghost btn-sm btn-square text-error"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                      </svg>
                    </button>
                  </div>
                <% end %>

                <p :if={Enum.empty?(keys)} class="text-base-content/50 text-sm py-2">
                  No API keys configured
                </p>
              </div>

              <!-- Add Key Form -->
              <%= if @adding_to == provider_slug do %>
                <.form for={@form} phx-change="validate" phx-submit="save" class="mt-4 p-4 bg-base-200 rounded-lg">
                  <div class="flex flex-col sm:flex-row gap-3">
                    <div class="flex-1">
                      <input
                        type="text"
                        name="provider_key[label]"
                        value={@form[:label].value}
                        placeholder="Label (e.g., Personal, Team)"
                        class={"input input-bordered w-full #{if @form[:label].errors != [], do: "input-error"}"}
                      />
                    </div>
                    <div class="flex-1">
                      <input
                        type="password"
                        name="provider_key[api_key]"
                        placeholder="API Key"
                        class="input input-bordered w-full"
                        autocomplete="off"
                      />
                    </div>
                    <div class="flex gap-2">
                      <button type="submit" class="btn btn-primary">Save</button>
                      <button type="button" phx-click="cancel_add" class="btn btn-ghost">Cancel</button>
                    </div>
                  </div>
                </.form>
              <% else %>
                <button
                  phx-click="start_add"
                  phx-value-provider={provider_slug}
                  class="btn btn-outline btn-sm mt-4"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                  </svg>
                  Add Key
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

end
