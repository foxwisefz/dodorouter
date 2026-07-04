defmodule DodoRouterWeb.LogLive.Index do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.{Logs, Routers}
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Proxy.Adapter.Registry

  @impl true
  def mount(_params, _session, socket) do
    routers = Routers.list_routers(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "Request Logs")
      |> assign(:routers, routers)
      |> assign(:selected_router_id, nil)
      |> assign(:selected_router, nil)
      |> assign(:subscribed_all, false)
      |> assign(:favorites_only, false)
      |> assign(:replay_counts, %{})
      |> stream(:logs, [])

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:subscribed_all] do
      unsubscribe_all_routers(socket)
    else
      if socket.assigns.selected_router_id do
        Logs.unsubscribe_from_logs(socket.assigns.selected_router_id)
      end
    end

    :ok
  end

  @impl true
  def handle_params(params, _url, socket) do
    router_id = params["router_id"]
    old_router_id = socket.assigns.selected_router_id
    was_all = old_router_id == nil && socket.assigns[:subscribed_all]
    favorites_only = params["favorites"] == "true"
    list_opts = [limit: 100, favorites_only: favorites_only]

    # Unsubscribe from previous subscriptions
    if connected?(socket) do
      if was_all do
        unsubscribe_all_routers(socket)
      else
        if old_router_id && old_router_id != router_id do
          Logs.unsubscribe_from_logs(old_router_id)
        end
      end
    end

    socket =
      if router_id do
        router = Routers.get_router!(socket.assigns.current_user, router_id)

        logs = Logs.list_logs(router, list_opts)
        # Subscribe to this router
        if connected?(socket) && old_router_id != router_id do
          Logs.subscribe_to_logs(router_id)
        end

        socket
        |> assign(:selected_router_id, router_id)
        |> assign(:selected_router, router)
        |> assign(:subscribed_all, false)
        |> assign(:favorites_only, favorites_only)
        |> assign(:replay_counts, Logs.replay_counts(Enum.map(logs, & &1.id)))
        |> stream(:logs, logs, reset: true)
      else
        # Show all logs across all routers

        logs = Logs.list_logs_for_user(socket.assigns.current_user, list_opts)
        # Subscribe to all routers
        if connected?(socket) && !was_all do
          subscribe_all_routers(socket)
        end

        socket
        |> assign(:selected_router_id, nil)
        |> assign(:selected_router, nil)
        |> assign(:subscribed_all, true)
        |> assign(:favorites_only, favorites_only)
        |> assign(:replay_counts, Logs.replay_counts(Enum.map(logs, & &1.id)))
        |> stream(:logs, logs, reset: true)
      end

    {:noreply, socket}
  end

  defp subscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.subscribe_to_logs(router.id)
    end)
  end

  defp unsubscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.unsubscribe_from_logs(router.id)
    end)
  end

  @impl true
  def handle_info({:log_pending, pending}, socket) do
    # Use request_id as stream key so completed log replaces it in place
    pending = Map.put(pending, :id, pending.request_id)
    {:noreply, stream_insert(socket, :logs, pending, at: 0)}
  end

  def handle_info({:log_created, log}, socket) do
    # Use request_id as key to replace pending entry in place
    log = Map.put(log, :id, log.request_id)
    {:noreply, stream_insert(socket, :logs, log)}
  end

  @impl true
  def handle_event("select_router", params, socket) do
    Logger.debug("select_router params: #{inspect(params)}")

    case params do
      %{"router_id" => ""} ->
        {:noreply, push_patch(socket, to: ~p"/logs")}

      %{"router_id" => router_id} ->
        {:noreply, push_patch(socket, to: ~p"/logs?router_id=#{router_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_favorite", %{"id" => id}, socket) do
    case Logs.toggle_favorite(socket.assigns.current_user, id) do
      {:ok, _log} ->
        {:noreply, reload_logs(socket)}

      _error ->
        {:noreply, socket}
    end
  end

  defp reload_logs(socket) do
    user = socket.assigns.current_user
    favorites_only = socket.assigns[:favorites_only]
    opts = [limit: 100, favorites_only: favorites_only]

    logs =
      if socket.assigns.selected_router_id do
        router = Routers.get_router!(user, socket.assigns.selected_router_id)
        Logs.list_logs(router, opts)
      else
        Logs.list_logs_for_user(user, opts)
      end

    stream(socket, :logs, logs, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-lg font-semibold text-base-content">Request Logs</h1>
          <p :if={@selected_router} class="text-sm text-base-content/50 mt-0.5">
            {@selected_router.name}
          </p>
        </div>

        <div class="flex items-center gap-2">
          <.link
            patch={favorites_toggle_path(@selected_router_id, @favorites_only)}
            class={[
              "btn btn-sm gap-1.5",
              @favorites_only && "btn-primary",
              !@favorites_only && "btn-ghost"
            ]}
          >
            <.icon
              name={if @favorites_only, do: "hero-star-solid", else: "hero-star"}
              class="w-4 h-4"
            />
            <span>Favorites</span>
          </.link>
          <form phx-change="select_router" class="contents">
            <select
              name="router_id"
              class="py-2 px-3 bg-base-200 border border-base-300/50 rounded-lg text-sm w-full sm:w-48"
            >
              <option value="">All routers</option>
              <option
                :for={r <- @routers}
                value={r.id}
                selected={to_string(r.id) == @selected_router_id}
              >
                {r.name}
              </option>
            </select>
          </form>
        </div>
      </div>
      
    <!-- Logs Table -->
      <div class="rounded-lg border border-base-300/50 bg-base-100 overflow-hidden">
        <table class="w-full text-left">
          <thead>
            <tr class="border-b border-base-300/50 bg-secondary/30">
              <th class="px-2 py-2.5 text-xs font-medium text-base-content/50 w-10">
                <span class="sr-only">Favorite</span>
              </th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50">Time</th>
              <th :if={!@selected_router} class="px-4 py-2.5 text-xs font-medium text-base-content/50">
                Router
              </th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50">Status</th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden sm:table-cell">
                Provider / Model
              </th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                Type
              </th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                Tokens
              </th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50">Latency</th>
              <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                Message
              </th>
            </tr>
          </thead>
          <tbody id="logs" phx-update="stream" class="divide-y divide-base-300/30">
            <tr
              :for={{dom_id, log} <- @streams.logs}
              id={dom_id}
              phx-click={log.status != "pending" && JS.navigate(~p"/logs/#{log}")}
              class={[
                "hover:bg-secondary/20 transition-colors",
                log.status == "pending" && "animate-pulse",
                log.status != "pending" && "cursor-pointer"
              ]}
            >
              <td class="px-2 py-2.5">
                <button
                  :if={log.status != "pending"}
                  type="button"
                  phx-click="toggle_favorite"
                  phx-value-id={log.id}
                  class={[
                    "btn btn-ghost btn-xs btn-square",
                    Map.get(log, :favorite) && "text-warning"
                  ]}
                  title={if Map.get(log, :favorite), do: "Unfavorite", else: "Favorite"}
                >
                  <.icon
                    name={if Map.get(log, :favorite), do: "hero-star-solid", else: "hero-star"}
                    class="w-4 h-4"
                  />
                </button>
              </td>
              <td class="px-4 py-2.5 text-sm font-mono text-base-content/50">
                {format_time(log.inserted_at)}
              </td>
              <td :if={!@selected_router} class="px-4 py-2.5 text-sm">
                <.link
                  :if={is_struct(Map.get(log, :router), DodoRouter.Routers.Router)}
                  navigate={~p"/routers/#{log.router}"}
                  class="text-primary hover:underline"
                >
                  {log.router.name}
                </.link>
              </td>
              <td class="px-4 py-2.5">
                <div class="flex items-center gap-1.5">
                  <.status_badge status={log.status} />
                  <span
                    :if={Map.get(log, :replayed_from_id)}
                    class="badge badge-ghost badge-xs gap-0.5"
                    title="Created by replaying another log"
                  >
                    <.icon name="hero-arrow-path" class="w-2.5 h-2.5" /> replay
                  </span>
                  <span
                    :if={Map.get(@replay_counts, Map.get(log, :id))}
                    class="badge badge-ghost badge-xs gap-0.5"
                    title={"Has #{Map.get(@replay_counts, Map.get(log, :id))} replays"}
                  >
                    <.icon name="hero-arrow-path" class="w-2.5 h-2.5" />
                    {Map.get(@replay_counts, Map.get(log, :id))}
                  </span>
                </div>
              </td>
              <td class="px-4 py-2.5 text-sm hidden sm:table-cell">
                <%= if is_list(Map.get(log, :attempted_steps)) and length(log.attempted_steps) > 1 do %>
                  <div class="flex items-center gap-1">
                    <%= for {step, idx} <- Enum.with_index(log.attempted_steps) do %>
                      <div class="flex items-center gap-1">
                        <div class="w-3.5 h-3.5 rounded flex items-center justify-center shrink-0 bg-base-200">
                          <.provider_logo
                            slug={
                              normalize_slug(
                                Registry.to_key_slug(
                                  step["provider"],
                                  step["plan_type"] || "standard"
                                )
                              )
                            }
                            class="w-2.5 h-2.5"
                          />
                        </div>
                        <span class={[
                          "text-xs px-1.5 py-0.5 rounded-full",
                          step["status"] == "success" && "bg-green-50 text-success",
                          step["status"] != "success" && "bg-red-50 text-error line-through"
                        ]}>
                          {step["provider"]}
                        </span>
                      </div>
                      <%= if idx < length(log.attempted_steps) - 1 do %>
                        <span class="text-base-content/30">→</span>
                      <% end %>
                    <% end %>
                  </div>
                  <div class="text-xs text-base-content/50 mt-0.5">{log.final_model}</div>
                <% else %>
                  <div class="flex items-center gap-2">
                    <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
                      <.provider_logo slug={normalize_slug(log.final_provider)} class="w-3 h-3" />
                    </div>
                    <span class="font-medium text-base-content">{log.final_provider}</span>
                    <span class="text-base-content/40"> / </span>
                    <span class="text-base-content/60">{log.final_model}</span>
                  </div>
                <% end %>
              </td>
              <td class="px-4 py-2.5 hidden md:table-cell">
                <.call_type_badge type={Map.get(log, :call_type)} />
              </td>
              <td class="px-4 py-2.5 text-sm font-mono text-base-content/50 hidden md:table-cell">
                <div class="flex items-center gap-1.5">
                  {Map.get(log, :total_tokens) || "-"}
                  <%= if Map.get(log, :cache_read_tokens) && log.cache_read_tokens > 0 do %>
                    <span class="inline-flex items-center gap-0.5 text-[10px] text-success bg-success/10 px-1 py-0.5 rounded">
                      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M13 10V3L4 14h7v7l9-11h-7z"
                        />
                      </svg>
                      {cache_pct(log)}
                    </span>
                  <% end %>
                </div>
              </td>
              <td class="px-4 py-2.5 text-sm font-mono text-base-content/50">
                {if Map.get(log, :latency_ms), do: "#{log.latency_ms}ms", else: "-"}
              </td>
              <td class="px-4 py-2.5 text-xs text-base-content/50 hidden md:table-cell max-w-xs truncate">
                {message_preview(log)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "bg-success/20 text-success"
        "fallback" -> "bg-warning/20 text-warning"
        "error" -> "bg-error/20 text-error"
        "pending" -> "bg-info/20 text-info"
        _ -> "bg-base-300 text-base-content/60"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}>{@status}</span>
    """
  end

  defp call_type_badge(assigns) do
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool", "bg-secondary/20 text-secondary"}
        "tool_enabled_completion" -> {"Tool+", "bg-primary/20 text-primary"}
        _ -> {"Chat", "bg-base-300 text-base-content/60"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}>{@label}</span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp message_preview(log) do
    if is_nil(Map.get(log, :request_body)) do
      nil
    else
      {messages, _} = MessageNormalizer.parse_request_body(log.request_body)

      messages
      |> Enum.reverse()
      |> Enum.find(fn msg ->
        msg.role in ~w(user assistant)
      end)
      |> case do
        nil -> nil
        %{content: content} when is_binary(content) and content != "" -> truncate_preview(content)
        %{reasoning_content: rc} when is_binary(rc) and rc != "" -> truncate_preview(rc)
        _ -> nil
      end
    end
  end

  defp truncate_preview(nil), do: ""

  defp truncate_preview(content) do
    if String.length(content) > 80 do
      String.slice(content, 0, 80) <> "..."
    else
      content
    end
  end

  defp cache_pct(log) do
    cached = log.cache_read_tokens || 0
    prompt = log.prompt_tokens || 0

    if prompt > 0 do
      pct = Float.round(cached / prompt * 100, 0)
      "#{trunc(pct)}%"
    else
      ""
    end
  end

  defp favorites_toggle_path(router_id, current?) do
    params =
      if router_id,
        do: %{"router_id" => router_id},
        else: %{}

    params =
      if current?,
        do: Map.delete(params, "favorites"),
        else: Map.put(params, "favorites", "true")

    ~p"/logs?#{params}"
  end
end
