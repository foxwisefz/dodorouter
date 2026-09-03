defmodule DodoRouterWeb.LogLive.Index do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.{Logs, Routers}
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Logs.PendingLog
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Usage

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
      |> assign(:failures_only, false)
      |> assign(:failure_breakdown, [])
      |> assign(:replay_counts, %{})
      |> assign(:log_count, 0)
      |> assign(:log_shown_count, 0)
      |> assign(:latency_percentiles, nil)
      # In-flight rows by request_id: LiveView streams can't be read back, so
      # a :log_pending_update (a fallback firing mid-request) rebuilds the row
      # from this copy. Entries leave when the terminal :log_created arrives.
      |> assign(:pending_by_request, %{})
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
    failures_only = params["failures"] == "true"

    list_opts =
      [limit: 100, favorites_only: favorites_only, failures_only: failures_only] ++
        failures_window_opts(failures_only)

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
        count = Logs.count_logs(router, list_opts)
        pending = mount_pending(failures_only, [router.id])

        # Percentiles are per-router; the all-routers view has no single
        # baseline to compare against, so latency coloring is skipped there.
        # Recomputed only here (mount/param change), not on every
        # :log_created, to avoid hammering the DB with a percentile query
        # per incoming request — a bit of staleness is an acceptable trade.
        latency_percentiles = Logs.latency_percentiles(router)

        # Subscribe to this router
        if connected?(socket) && old_router_id != router_id do
          Logs.subscribe_to_logs(router_id)
        end

        socket
        |> assign(:selected_router_id, router_id)
        |> assign(:selected_router, router)
        |> assign(:subscribed_all, false)
        |> assign(:favorites_only, favorites_only)
        |> assign(:failures_only, failures_only)
        |> assign(
          :failure_breakdown,
          if(failures_only, do: Logs.failure_breakdown(router), else: [])
        )
        |> assign(:replay_counts, Logs.replay_counts(Enum.map(logs, & &1.id)))
        |> assign(:log_count, count)
        |> assign(:log_shown_count, length(logs))
        |> assign(:latency_percentiles, latency_percentiles)
        |> assign(:pending_by_request, Map.new(pending, &{&1.request_id, &1}))
        |> stream(:logs, pending_rows(pending) ++ logs, reset: true)
      else
        # Show all logs across all routers

        logs = Logs.list_logs_for_user(socket.assigns.current_user, list_opts)
        count = Logs.count_logs_for_user(socket.assigns.current_user, list_opts)
        pending = mount_pending(failures_only, Enum.map(socket.assigns.routers, & &1.id))
        # Subscribe to all routers
        if connected?(socket) && !was_all do
          subscribe_all_routers(socket)
        end

        socket
        |> assign(:selected_router_id, nil)
        |> assign(:selected_router, nil)
        |> assign(:subscribed_all, true)
        |> assign(:favorites_only, favorites_only)
        |> assign(:failures_only, failures_only)
        # The breakdown is per-router; the all-routers view still filters
        # the list correctly, it just has no single router to summarize.
        |> assign(:failure_breakdown, [])
        |> assign(:replay_counts, Logs.replay_counts(Enum.map(logs, & &1.id)))
        |> assign(:log_count, count)
        |> assign(:log_shown_count, length(logs))
        |> assign(:latency_percentiles, nil)
        |> assign(:pending_by_request, Map.new(pending, &{&1.request_id, &1}))
        |> stream(:logs, pending_rows(pending) ++ logs, reset: true)
      end

    {:noreply, socket}
  end

  # Failure mode is time-boxed to a fixed trailing 24h window, applied in
  # the query itself — so the "showing X of N" header gives an honest,
  # windowed denominator rather than counting failures since the dawn of
  # the router.
  @failure_window_hours 24

  defp failures_window_opts(true),
    do: [from: DateTime.add(DateTime.utc_now(), -@failure_window_hours * 3600, :second)]

  defp failures_window_opts(_), do: []

  # Requests already in flight have no request_logs row yet, and their
  # :log_pending broadcast fired before this stream (re)build — Activity holds
  # their payloads. Skipped under the failures filter, matching the
  # :log_pending handler: a pending request has no terminal status yet.
  defp mount_pending(true = _failures_only, _router_ids), do: []
  defp mount_pending(false, router_ids), do: DodoRouter.Activity.list_pending(router_ids)

  # Use request_id as stream key so the completed log replaces the row in place
  defp pending_rows(pending), do: Enum.map(pending, &Map.put(&1, :id, &1.request_id))

  defp subscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.subscribe_to_logs(router.id)
    end)
  end

  defp drop_pending(socket, request_id) do
    assign(socket, :pending_by_request, Map.delete(socket.assigns.pending_by_request, request_id))
  end

  defp unsubscribe_all_routers(socket) do
    Enum.each(socket.assigns.routers, fn router ->
      Logs.unsubscribe_from_logs(router.id)
    end)
  end

  @impl true
  def handle_info({:log_pending, _pending}, %{assigns: %{failures_only: true}} = socket) do
    # A pending request has no terminal status yet, so it can't be known to
    # be a failure — and it isn't counted by the query either. Skip the
    # insert entirely rather than show (then possibly yank) a row.
    {:noreply, socket}
  end

  def handle_info({:log_pending, pending}, socket) do
    # Use request_id as stream key so completed log replaces it in place
    pending = Map.put(pending, :id, pending.request_id)

    socket =
      socket
      |> assign(
        :pending_by_request,
        Map.put(socket.assigns.pending_by_request, pending.request_id, pending)
      )
      |> stream_insert(:logs, pending, at: 0)

    {:noreply, socket}
  end

  def handle_info({:log_pending_update, _update}, %{assigns: %{failures_only: true}} = socket) do
    # The pending row was never shown under this filter, so there is nothing
    # to move to the backup provider.
    {:noreply, socket}
  end

  def handle_info({:log_pending_update, update}, socket) do
    # A fallback fired mid-request: the row announced with the first step's
    # provider is now being served by the backup. Mark the failed hop and show
    # the step actually running, so the switch is visible while in flight.
    case socket.assigns.pending_by_request[update.request_id] do
      nil ->
        {:noreply, socket}

      pending ->
        pending = PendingLog.apply_fallback(pending, update)

        socket =
          socket
          |> assign(
            :pending_by_request,
            Map.put(socket.assigns.pending_by_request, update.request_id, pending)
          )
          |> stream_insert(:logs, pending)

        {:noreply, socket}
    end
  end

  def handle_info({:log_created, log}, %{assigns: %{failures_only: true}} = socket) do
    # The terminal status arrives here, so a pending -> error transition
    # still lands even though :log_pending was skipped for it. A log
    # outside the failure set is simply not part of the filtered view —
    # counts stay honest by only bumping them for what actually matches.
    if log.status in ["error", "fallback"] do
      log = Map.put(log, :id, log.request_id)

      socket =
        socket
        |> assign(:log_count, socket.assigns.log_count + 1)
        |> assign(:log_shown_count, socket.assigns.log_shown_count + 1)
        |> drop_pending(log.request_id)
        |> stream_insert(:logs, log)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:log_created, log}, socket) do
    # Use request_id as key to replace pending entry in place
    log = Map.put(log, :id, log.request_id)

    socket =
      socket
      |> assign(:log_count, socket.assigns.log_count + 1)
      |> assign(:log_shown_count, socket.assigns.log_shown_count + 1)
      |> drop_pending(log.request_id)
      |> stream_insert(:logs, log)

    {:noreply, socket}
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
    failures_only = socket.assigns[:failures_only]

    opts =
      [limit: 100, favorites_only: favorites_only, failures_only: failures_only] ++
        failures_window_opts(failures_only)

    {logs, count, latency_percentiles} =
      if socket.assigns.selected_router_id do
        router = Routers.get_router!(user, socket.assigns.selected_router_id)

        {Logs.list_logs(router, opts), Logs.count_logs(router, opts),
         Logs.latency_percentiles(router)}
      else
        {Logs.list_logs_for_user(user, opts), Logs.count_logs_for_user(user, opts), nil}
      end

    socket
    |> assign(:log_count, count)
    |> assign(:log_shown_count, length(logs))
    |> assign(:latency_percentiles, latency_percentiles)
    |> stream(:logs, logs, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <!-- Header -->
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-lg font-semibold text-base-content">Request Logs</h1>
            <p :if={@selected_router} class="text-sm text-base-content/50 mt-0.5">
              {@selected_router.name}
            </p>
            <p id="logs-count" class="text-sm text-base-content/50 mt-0.5">
              <%= if @log_count > @log_shown_count do %>
                showing {@log_shown_count} of {pluralize(@log_count, "request")}
              <% else %>
                {pluralize(@log_count, "request")}
              <% end %>
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
            <.link
              patch={failures_toggle_path(@selected_router_id, @failures_only)}
              class={[
                "btn btn-sm gap-1.5",
                @failures_only && "btn-error",
                !@failures_only && "btn-ghost"
              ]}
            >
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <span>Failures</span>
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
        
    <!-- Failure breakdown banner -->
        <div
          :if={@failures_only and @failure_breakdown != []}
          id="failure-breakdown"
          class="mb-4 flex flex-wrap gap-2"
        >
          <span
            :for={row <- @failure_breakdown}
            class={[
              "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium",
              row.status == "error" && "bg-error/10 text-error",
              row.status == "fallback" && "bg-warning/10 text-warning"
            ]}
          >
            {row.count} {if row.status == "error", do: "errors", else: "fallbacks"} on {row.provider}/{row.model} · last 24h
          </span>
        </div>
        
    <!-- Logs Table -->
        <div class="rounded-lg border border-base-300/50 bg-base-100 overflow-hidden">
          <table class="w-full text-left">
            <thead>
              <%!-- Columns are grouped for the failure-reading path first:
                 time places it, then status / provider-model / latency sit
                 contiguous because those three co-vary when something goes
                 wrong (which hop, on which provider, took how long) — rather
                 than the previous production order that scattered them
                 behind Router and Type. Everything after Latency is
                 secondary context, not part of that read. --%>
              <tr class="border-b border-base-300/50 bg-secondary/30">
                <th class="px-2 py-2.5 text-xs font-medium text-base-content/50 w-10">
                  <span class="sr-only">Favorite</span>
                </th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50">Time</th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50">Status</th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden sm:table-cell">
                  Provider / Model
                </th>
                <th
                  class="px-4 py-2.5 text-xs font-medium text-base-content/50"
                  title={latency_baseline_title(@latency_percentiles)}
                >
                  Latency
                </th>
                <th
                  :if={!@selected_router}
                  class="px-4 py-2.5 text-xs font-medium text-base-content/50"
                >
                  Router
                </th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                  Type
                </th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                  Tokens
                </th>
                <th class="px-4 py-2.5 text-xs font-medium text-base-content/50 hidden md:table-cell">
                  Message
                </th>
              </tr>
            </thead>
            <tbody id="logs" phx-update="stream" class="divide-y divide-base-300/30">
              <tr id="logs-empty" class="hidden only:table-row">
                <td colspan="9" class="px-4 py-16 text-center">
                  <div class="flex flex-col items-center gap-2">
                    <.icon name="hero-clock" class="size-8 text-base-content/20" />
                    <p class="text-sm font-medium text-base-content/60">
                      {if @favorites_only, do: "No favorite requests yet", else: "No requests yet"}
                    </p>
                    <p :if={!@favorites_only} class="text-sm text-base-content/40">
                      Send a request to a router and it will show up here in real time.
                      <.link navigate={~p"/routers"} class="text-primary hover:underline">
                        View your routers
                      </.link>
                    </p>
                  </div>
                </td>
              </tr>
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
                <td class="px-4 py-2.5">
                  <div class="flex items-center gap-1.5">
                    <.status_badge status={log.status} />
                    <span
                      :if={Map.get(log, :replayed_from_id)}
                      class="badge badge-ghost badge-xs gap-0.5"
                      title={replay_badge_title(log)}
                    >
                      <.icon name="hero-arrow-path" class="w-2.5 h-2.5" />
                      {replay_badge_label(log)}
                    </span>
                    <span
                      :if={Map.get(@replay_counts, Map.get(log, :id))}
                      class="badge badge-ghost badge-xs gap-0.5"
                      title={"Has #{pluralize(Map.get(@replay_counts, Map.get(log, :id)), "replay")}"}
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
                            step["status"] == "error" && "bg-red-50 text-error line-through",
                            step["status"] not in ["success", "error"] &&
                              "bg-base-200 text-base-content/70"
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
                <td
                  class={[
                    "px-4 py-2.5 text-sm font-mono",
                    latency_band_class(Map.get(log, :latency_ms), @latency_percentiles)
                  ]}
                  data-latency-band={latency_band(Map.get(log, :latency_ms), @latency_percentiles)}
                >
                  {if Map.get(log, :latency_ms), do: "#{log.latency_ms}ms", else: "-"}
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
                <td class="px-4 py-2.5 text-xs text-base-content/50 hidden md:table-cell max-w-xs truncate">
                  {message_preview(log)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
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
    class =
      case assigns.type do
        "tool_call" -> "bg-secondary/20 text-secondary"
        "tool_enabled_completion" -> "bg-primary/20 text-primary"
        _ -> "bg-base-300 text-base-content/60"
      end

    assigns = assign(assigns, label: call_type_name(assigns.type), class: class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}>{@label}</span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  # Bare "340ms" doesn't say whether that's normal — banding it against the
  # router's own p50/p95 makes an outlier visible without leaving the page.
  defp latency_band(latency_ms, percentiles) do
    with true <- is_integer(latency_ms) or is_float(latency_ms),
         %{p50: p50, p95: p95} <- percentiles,
         true <- is_number(p50) and is_number(p95) do
      cond do
        latency_ms > p95 -> "slow"
        latency_ms > p50 -> "elevated"
        true -> "normal"
      end
    else
      _ -> nil
    end
  end

  defp latency_band_class(latency_ms, percentiles) do
    case latency_band(latency_ms, percentiles) do
      "slow" -> "text-error"
      "elevated" -> "text-warning"
      _ -> "text-base-content/50"
    end
  end

  defp latency_baseline_title(nil), do: "No latency baseline available for this view"

  defp latency_baseline_title(%{p50: p50, p95: p95}) when is_number(p50) and is_number(p95) do
    "Colored against this router's p50 #{round(p50)}ms / p95 #{round(p95)}ms (last 24h)"
  end

  defp latency_baseline_title(_), do: "Not enough data yet for a latency baseline"

  defp replay_badge_label(log) do
    case Map.get(log, :replay_from_index) do
      index when is_integer(index) -> "rerun · ##{index + 1}"
      _other -> "rerun"
    end
  end

  defp replay_badge_title(log) do
    case Map.get(log, :replay_from_index) do
      index when is_integer(index) -> "Replay of another log — from message #{index + 1}"
      _other -> "Replay of another log (full thread)"
    end
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
    case Usage.cache_hit_pct(log.prompt_tokens, log.cache_read_tokens, log.cache_write_tokens, 0) do
      nil -> ""
      pct -> "#{trunc(pct)}%"
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

  defp failures_toggle_path(router_id, current?) do
    params =
      if router_id,
        do: %{"router_id" => router_id},
        else: %{}

    params =
      if current?,
        do: Map.delete(params, "failures"),
        else: Map.put(params, "failures", "true")

    ~p"/logs?#{params}"
  end
end
