defmodule DodoRouterWeb.ProvidersLive.Index do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Providers.KeyVerifier

  alias DodoRouter.Evaluations
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
      |> assign(
        :display_slugs,
        Enum.reject(ProviderKey.provider_slugs(), &(&1 == "test_provider"))
      )
      |> assign(:adding_to, nil)
      |> assign(:editing_key, nil)
      |> assign(:highlighted_key_id, nil)
      |> assign(:filtered_provider, nil)
      |> assign(:form, nil)
      |> assign(:codex_device, nil)
      |> assign(:codex_timer, nil)
      |> assign(:blocked_delete, nil)
      |> assign(:verifying, MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    return_to =
      case params["return_to"] do
        "/routers/" <> _ = path -> path
        _ -> nil
      end

    socket =
      socket
      |> assign(:highlighted_key_id, params["highlight"])
      |> assign(:filtered_provider, params["provider"])
      |> assign(:return_to, return_to)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_provider", %{"provider" => provider_slug}, socket) do
    {:noreply, assign(socket, :filtered_provider, provider_slug)}
  end

  def handle_event("reverify", %{"id" => id}, socket) do
    case Providers.get_provider_key(socket.assigns.current_user, id) do
      nil -> {:noreply, socket}
      key -> {:noreply, start_verification(socket, key)}
    end
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
    if socket.assigns[:codex_timer], do: Process.cancel_timer(socket.assigns.codex_timer)
    {:noreply, assign(socket, adding_to: nil, form: nil, codex_device: nil, codex_timer: nil)}
  end

  def handle_event("start_codex_device", _params, socket) do
    case DodoRouter.OpenAICodexOAuth.start_device_authorization() do
      {:ok, device} ->
        timer = Process.send_after(self(), :poll_codex_device, device.interval * 1000)
        {:noreply, assign(socket, codex_device: device, codex_timer: timer)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to start ChatGPT authorization. Please try again.")}
    end
  end

  def handle_event("cancel_codex_device", _params, socket) do
    if socket.assigns[:codex_timer], do: Process.cancel_timer(socket.assigns.codex_timer)
    {:noreply, assign(socket, codex_device: nil, codex_timer: nil)}
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
        {:ok, provider_key} ->
          provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

          socket =
            socket
            |> assign(:provider_keys, provider_keys)
            |> assign(:adding_to, nil)
            |> assign(:form, nil)
            |> put_flash(:info, "API key added")
            |> start_verification(provider_key)

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

    case Providers.delete_provider_key(provider_key) do
      {:ok, _} ->
        {:noreply, key_removed(socket)}

      {:error, :in_use} ->
        {:noreply, assign(socket, :blocked_delete, blocked_delete(provider_key))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove this key")}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :blocked_delete, nil)}
  end

  def handle_event(
        "reassign_and_delete",
        %{"key_id" => id, "replacement_id" => replacement_id},
        socket
      ) do
    user = socket.assigns.current_user
    provider_key = Providers.get_provider_key!(user, id)
    replacement = Providers.get_provider_key(user, replacement_id)

    case replacement && Providers.delete_provider_key(provider_key, reassign_to: replacement) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:blocked_delete, nil)
         |> key_removed("Evaluations moved to #{replacement.label}, key removed")}

      nil ->
        {:noreply, put_flash(socket, :error, "Pick a key to move the evaluations to")}

      {:error, :in_use} ->
        {:noreply,
         socket
         |> assign(:blocked_delete, blocked_delete(provider_key))
         |> put_flash(:error, "Something else still references this key")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not move the evaluations to that key")}
    end
  end

  defp key_removed(socket, message \\ "API key removed") do
    socket
    |> assign(:provider_keys, Providers.list_provider_keys_grouped(socket.assigns.current_user))
    |> assign(:blocked_delete, nil)
    |> put_flash(:info, message)
  end

  defp blocked_delete(provider_key) do
    counts = Evaluations.reference_counts(provider_key)

    %{
      key_id: provider_key.id,
      counts: counts,
      replacements: Providers.reassignment_candidates(provider_key)
    }
  end

  # "3 evaluations (judge of 2, candidate in 2)" — the total is distinct, so
  # the roles can overlap and still add up to fewer evaluations than roles.
  # Naming the roles matters because only one is a real foreign key, and a
  # reader who deletes evaluations to unblock themselves needs to know which.
  defp reference_summary(%{judge: judge, candidate: candidate, total: total}) do
    roles = Enum.reject([role(judge, "judge of"), role(candidate, "candidate in")], &is_nil/1)

    "#{pluralize(total, "evaluation")} (#{Enum.join(roles, ", ")})"
  end

  defp role(0, _name), do: nil
  defp role(count, name), do: "#{name} #{count}"

  @impl true
  def handle_info(:poll_codex_device, socket) do
    %{
      device_auth_id: device_auth_id,
      user_code: user_code,
      interval: interval
    } = socket.assigns.codex_device

    case DodoRouter.OpenAICodexOAuth.complete_device_authorization(device_auth_id, user_code) do
      {:ok, encoded_credentials} ->
        existing_keys = Map.get(socket.assigns.provider_keys, "openai-codex", [])
        label = next_label(existing_keys)
        attrs = %{provider_slug: "openai-codex", label: label}

        hint =
          case Jason.decode(encoded_credentials) do
            {:ok, %{"access" => access}} when is_binary(access) ->
              Providers.generate_key_hint(access)

            _ ->
              "OAuth"
          end

        case Providers.create_provider_key_with_hint(
               socket.assigns.current_user,
               attrs,
               encoded_credentials,
               hint
             ) do
          {:ok, _provider_key} ->
            provider_keys = Providers.list_provider_keys_grouped(socket.assigns.current_user)

            socket =
              socket
              |> assign(:provider_keys, provider_keys)
              |> assign(:adding_to, nil)
              |> assign(:form, nil)
              |> assign(:codex_device, nil)
              |> assign(:codex_timer, nil)
              |> put_flash(:info, "ChatGPT connected successfully")

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(codex_device: nil, codex_timer: nil)
             |> put_flash(:error, "Failed to store credentials")}
        end

      {:pending, _reason} ->
        timer = Process.send_after(self(), :poll_codex_device, interval * 1000)
        {:noreply, assign(socket, codex_timer: timer)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(codex_device: nil, codex_timer: nil)
         |> put_flash(:error, "ChatGPT authorization failed. Please try again.")}
    end
  end

  @impl true
  def handle_async({:verify_key, key_id}, result, socket) do
    case result do
      {:ok, {:ok, :valid}} ->
        Providers.mark_key_verified(key_id)

      {:ok, {:ok, :unverifiable}} ->
        :ok

      {:ok, {:error, class, detail}} ->
        Providers.apply_health(key_id, class, detail)

      {:exit, _reason} ->
        :ok
    end

    {:noreply,
     socket
     |> assign(:verifying, MapSet.delete(socket.assigns.verifying, key_id))
     |> assign(
       :provider_keys,
       Providers.list_provider_keys_grouped(socket.assigns.current_user)
     )}
  end

  defp start_verification(socket, key) do
    socket
    |> assign(:verifying, MapSet.put(socket.assigns.verifying, key.id))
    |> start_async({:verify_key, key.id}, fn -> KeyVerifier.verify(key) end)
  end

  attr :key, :map, required: true
  attr :verifying, :any, required: true

  defp key_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% MapSet.member?(@verifying, @key.id) -> %>
        <span class="loading loading-spinner loading-xs text-base-content/40" title="Verifying key…">
        </span>
      <% @key.status == "valid" -> %>
        <span title={"Verified — last OK " <> relative_time(@key.last_ok_at || @key.verified_at)}>
          <.icon name="hero-check-circle" class="size-4 text-success" />
        </span>
      <% @key.status == "invalid" -> %>
        <span title={"Invalid since " <> relative_time(@key.last_error_at) <> " — " <> (@key.last_error_detail || "authentication failed")}>
          <.icon name="hero-x-circle" class="size-4 text-error" />
        </span>
      <% @key.status == "quota_exceeded" -> %>
        <span title={"Out of credits/quota since " <> relative_time(@key.last_error_at)}>
          <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
        </span>
      <% true -> %>
        <button
          phx-click="reverify"
          phx-value-id={@key.id}
          class="text-base-content/40 hover:text-base-content transition-colors"
          title="Not verified yet — click to verify"
        >
          <.icon name="hero-question-mark-circle" class="size-4" />
        </button>
    <% end %>
    """
  end

  attr :key, :map, required: true
  attr :provider_name, :string, required: true
  attr :blocked, :map, required: true

  # Shown in place of the crash a restricting foreign key used to produce —
  # and in place of the silent success the candidate references, which no
  # foreign key protects, used to get. Either way the reference is worth
  # keeping (the evaluation can be re-run), so the way out is to name
  # another key, not to force the delete through.
  defp judge_block_notice(assigns) do
    ~H"""
    <div
      id={"judge-block-#{@key.id}"}
      class="px-4 py-3 border-b border-base-300/20 last:border-b-0 bg-warning/5"
    >
      <p class="text-sm mb-2">
        <span class="font-medium">{@key.label}</span>
        is used by {reference_summary(@blocked.counts)}, which can be re-run.
      </p>
      <%= if @blocked.replacements == [] do %>
        <div class="flex items-center gap-2">
          <p class="text-xs text-base-content/60 flex-1">
            Add another {@provider_name} key to move them to, then remove this one.
          </p>
          <button type="button" phx-click="cancel_delete" class="btn btn-xs btn-ghost">Cancel</button>
        </div>
      <% else %>
        <form
          id={"reassign-judge-#{@key.id}"}
          phx-submit="reassign_and_delete"
          class="flex items-center gap-2"
        >
          <input type="hidden" name="key_id" value={@key.id} />
          <select
            name="replacement_id"
            class="flex-1 px-2 py-1.5 bg-base-100 border border-base-300/50 rounded text-sm focus:outline-none focus:border-primary/50"
          >
            <option :for={replacement <- @blocked.replacements} value={replacement.id}>
              {replacement.label} — {Providers.compact_key_hint(replacement.key_hint)}
            </option>
          </select>
          <button type="submit" class="btn btn-sm btn-primary">Move & remove</button>
          <button type="button" phx-click="cancel_delete" class="btn btn-sm btn-ghost">Cancel</button>
        </form>
      <% end %>
    </div>
    """
  end

  defp relative_time(nil), do: "recently"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-2xl">
        <!-- Header -->
        <div class="mb-8">
          <h1 class="text-2xl font-bold">Providers</h1>
          <p class="text-base-content/50 text-sm">Connect your LLM provider API keys</p>
        </div>

        <div
          :if={@return_to}
          id="return-to-router"
          class="mb-6 flex items-center justify-between gap-3 rounded-xl border border-primary/30 bg-primary/5 px-4 py-3"
        >
          <p class="text-sm text-base-content/70">
            You're setting up a router — add a key below, then continue where you left off.
          </p>
          <.link navigate={@return_to} class="btn btn-primary btn-sm shrink-0">
            Continue setup →
          </.link>
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
          <%= for provider_slug <- @display_slugs do %>
            <% info = @provider_info[provider_slug] %>
            <button
              type="button"
              phx-click="filter_provider"
              phx-value-provider={provider_slug}
              class={[
                "px-3 py-1.5 text-xs font-medium rounded-lg transition",
                @filtered_provider == provider_slug && "bg-primary text-primary-content",
                @filtered_provider != provider_slug &&
                  "bg-base-200 text-base-content hover:bg-base-300"
              ]}
            >
              {info.name}
            </button>
          <% end %>
        </div>
        
    <!-- Provider Cards -->
        <div class="space-y-3">
          <%= for provider_slug <- @display_slugs do %>
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
                            <.key_status_badge key={key} verifying={@verifying} />
                            <button
                              phx-click="start_edit"
                              phx-value-id={key.id}
                              class="text-sm hover:text-primary transition-colors"
                            >
                              {key.label}
                              <span class="text-base-content/40 font-mono text-xs ml-1.5">
                                {Providers.compact_key_hint(key.key_hint)}
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
                      <.judge_block_notice
                        :if={@blocked_delete && @blocked_delete.key_id == key.id}
                        key={key}
                        provider_name={info.name}
                        blocked={@blocked_delete}
                      />
                    <% end %>
                    
    <!-- Add Key Form -->
                    <%= if @adding_to == provider_slug do %>
                      <div class="px-4 py-3 space-y-3">
                        <%= if provider_slug == "openai-codex" && @codex_device do %>
                          <div class="text-center space-y-3 py-2">
                            <div class="flex items-center gap-2 justify-center text-sm text-base-content/60">
                              <span class="loading loading-spinner loading-sm"></span>
                              Waiting for authorization...
                            </div>
                            <p class="text-xs text-base-content/50">
                              Enter this code at the URL below
                            </p>
                            <a
                              href={@codex_device.verification_uri}
                              target="_blank"
                              rel="noopener noreferrer"
                              class="text-primary hover:underline text-sm font-medium inline-flex items-center gap-1"
                            >
                              {@codex_device.verification_uri}
                              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                            </a>
                            <div class="text-2xl font-mono font-bold tracking-widest py-3 px-6 bg-base-100 rounded-lg inline-block border border-base-300/50 select-all">
                              {@codex_device.user_code}
                            </div>
                            <div>
                              <button
                                type="button"
                                phx-click="cancel_codex_device"
                                class="btn btn-sm btn-ghost"
                              >
                                Cancel
                              </button>
                            </div>
                          </div>
                        <% else %>
                          <%= if provider_slug == "openai-codex" do %>
                            <div>
                              <button
                                type="button"
                                phx-click="start_codex_device"
                                class="btn btn-sm btn-primary inline-flex items-center gap-2"
                              >
                                <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
                                Connect with ChatGPT
                              </button>
                              <p class="text-xs text-base-content/50 mt-1">
                                Authorize via your ChatGPT account (Plus/Pro subscription)
                              </p>
                            </div>
                            <div class="relative">
                              <div class="absolute inset-0 flex items-center">
                                <div class="w-full border-t border-base-300/40"></div>
                              </div>
                              <div class="relative flex justify-center text-xs">
                                <span class="px-2 bg-base-200/30 text-base-content/50">
                                  or paste token manually
                                </span>
                              </div>
                            </div>
                          <% end %>
                          <%= if info.key_generation_url do %>
                            <div>
                              <a
                                href={info.key_generation_url}
                                target="_blank"
                                rel="noopener noreferrer"
                                class="text-xs text-primary hover:underline inline-flex items-center gap-1"
                              >
                                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                                Get your API key from {info.name}
                              </a>
                            </div>
                          <% end %>
                          <.form
                            for={@form}
                            phx-submit="save"
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
                              <button
                                type="button"
                                phx-click="cancel_add"
                                class="btn btn-sm btn-ghost"
                              >
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
            <% end %>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp next_label(existing_keys) do
    count = length(existing_keys) + 1
    "Key #{count}"
  end
end
