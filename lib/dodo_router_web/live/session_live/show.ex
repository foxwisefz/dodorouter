defmodule DodoRouterWeb.SessionLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.CacheRegression
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Routers
  alias DodoRouter.TextDiff
  alias DodoRouterWeb.Components.Charts

  @impl true
  def mount(%{"router_id" => router_id, "session_id" => session_id}, _session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, router_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:logs")
    end

    socket =
      socket
      |> assign(:router, router)
      |> assign(:session_id, session_id)
      |> assign(:page_title, "Session #{session_id}")
      |> assign(:editing_name, false)
      |> load_data()

    {:ok, socket}
  end

  def mount(_params, _socket_session, socket) do
    {:ok, redirect(socket, to: ~p"/routers")}
  end

  @impl true
  def handle_info({:log_created, log}, socket) do
    if log.session_id == socket.assigns.session_id do
      {:noreply, load_data(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("edit_name", _params, socket) do
    {:noreply, assign(socket, :editing_name, true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_name, false)}
  end

  def handle_event("save_name", %{"session_name" => session_name}, socket) do
    router = socket.assigns.router
    session_id = socket.assigns.session_id

    Logs.update_session_name(router, session_id, session_name)

    {:noreply,
     socket
     |> assign(:editing_name, false)
     |> assign(:session_name, session_name)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <div class="flex items-center gap-3 mb-6">
          <a href={~p"/routers/#{@router.id}/sessions"} class="btn btn-ghost btn-sm btn-circle">←</a>
          <div class="flex-1">
            <%= if @editing_name do %>
              <form phx-submit="save_name" class="flex items-center gap-2">
                <input
                  type="text"
                  name="session_name"
                  value={@session_name || ""}
                  placeholder="Session name"
                  class="input input-sm input-bordered w-full max-w-xs"
                  phx-mounted={JS.focus()}
                />
                <button type="submit" class="btn btn-sm btn-primary">Save</button>
                <button type="button" phx-click="cancel_edit" class="btn btn-sm btn-ghost">
                  Cancel
                </button>
              </form>
            <% else %>
              <div class="flex items-center gap-2">
                <h1 class="text-xl font-bold">
                  {if @session_name, do: @session_name, else: "Session"}
                </h1>
                <button phx-click="edit_name" class="btn btn-ghost btn-xs" title="Edit name">
                  <.icon name="hero-pencil" class="size-3" />
                </button>
              </div>
            <% end %>
            <p class="text-sm font-mono text-base-content/50">{@session_id}</p>
          </div>
        </div>
        
    <!-- Stats -->
        <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
          <Charts.stat_tile
            id="session-requests"
            label="Requests"
            value={to_string(@stats.request_count)}
          />
          <Charts.stat_tile
            id="session-cost"
            label="Cost"
            value={format_usd(@stats.total_cost_usd)}
            subtext={
              if would_be_cost(@stats), do: "~#{format_usd(would_be_cost(@stats))} at API rates"
            }
          />
          <Charts.stat_tile
            id="session-tokens"
            label="Total Tokens"
            value={to_string(@stats.total_tokens || 0)}
          />
          <Charts.stat_tile
            id="session-latency"
            label="p95 Latency"
            value={"#{format_latency(@latency_percentiles.p95)}ms"}
            subtext={"p50 #{format_latency(@latency_percentiles.p50)}ms"}
          />
          <Charts.stat_tile
            id="session-success"
            label="Success Rate"
            value={
              if @stats.request_count > 0,
                do: "#{round((@stats.successful_requests || 0) / @stats.request_count * 100)}%",
                else: "—"
            }
          />
        </div>

        <.cache_regression_notice :if={@cache_regression} finding={@cache_regression} />
        
    <!-- What the session's input tokens were made of. Shares are pro-rata
       allocations of the billed totals (no provider tokenizer is public),
       so the percentages are the trustworthy part. -->
        <div :if={attribution_rows(@token_attribution) != []} class="mb-6">
          <h2 class="text-lg font-semibold mb-3">Context breakdown</h2>
          <div
            id="session-token-attribution"
            class="bg-base-100 border border-base-300 rounded-lg p-4 space-y-2 text-xs max-w-xl"
          >
            <div :for={row <- attribution_rows(@token_attribution)} class="space-y-0.5">
              <div class="flex justify-between">
                <span class="text-base-content/60">{row.label}</span>
                <span class="font-mono">
                  {row.pct}% <span class="text-base-content/40">· ~{row.tokens}</span>
                  <span
                    :if={row.cached_pct > 0}
                    class="text-success"
                    title="Share of this segment that sat in the cacheable prefix"
                  >
                    {row.cached_pct}% cached
                  </span>
                </span>
              </div>
              <div class="h-1 rounded-full bg-base-300/60 overflow-hidden">
                <div class="h-full rounded-full bg-primary/70" style={"width: #{row.pct}%"}></div>
              </div>
              <div :if={row.by_tool != []} class="text-[10px] text-base-content/45 text-right">
                {Enum.map_join(row.by_tool, " · ", fn {tool, tokens} -> "#{tool} ~#{tokens}" end)}
              </div>
            </div>
            <p class="text-[10px] text-base-content/40 pt-1">
              Summed across {@token_attribution["rows"]} requests · shares of
              ~{@token_attribution["basis_tokens"]} billed input tokens, allocated pro-rata
            </p>
          </div>
        </div>
        
    <!-- Request timeline -->
        <h2 class="text-lg font-semibold mb-3">Requests</h2>
        <div class="space-y-2">
          <%= for log <- @logs do %>
            <a
              id={"turn-#{log.id}"}
              href={~p"/logs/#{log.id}" <> "?return_to=" <> URI.encode_www_form("/routers/#{@router.id}/sessions/#{@session_id}")}
              class={[
                "block p-3 rounded-lg text-sm transition-colors",
                log.status == "pending" && "bg-info/10 animate-pulse",
                log.status == "success" && "bg-success/10 hover:bg-success/20",
                log.status == "fallback" && "bg-warning/10 hover:bg-warning/20",
                log.status == "error" && "bg-error/10 hover:bg-error/20",
                diverging_turn?(@cache_regression, log) && "ring-2 ring-warning/60"
              ]}
            >
              <div
                :if={diverging_turn?(@cache_regression, log)}
                class="flex items-center gap-1.5 text-xs font-medium text-warning mb-2"
              >
                <.icon name="hero-scissors" class="size-3.5" /> Cache stopped hitting here
              </div>
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <span class={[
                    "w-2 h-2 rounded-full shrink-0",
                    log.status == "pending" && "bg-info",
                    log.status == "success" && "bg-success",
                    log.status == "fallback" && "bg-warning",
                    log.status == "error" && "bg-error"
                  ]}>
                  </span>
                  <div class="flex items-center gap-2">
                    <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
                      <.provider_logo slug={normalize_slug(log.final_provider)} class="w-3 h-3" />
                    </div>
                    <span class="font-mono text-base-content/80">
                      {log.final_provider}/{log.final_model}
                    </span>
                  </div>
                  <span
                    :if={log.call_type}
                    class="px-1.5 py-0.5 rounded text-xs font-medium bg-base-300/50 text-base-content/70"
                  >
                    {call_type_name(log.call_type)}
                  </span>
                  <span class={[
                    "px-1.5 py-0.5 rounded text-xs font-medium",
                    status_badge_class(log.status)
                  ]}>
                    {log.status}
                  </span>
                </div>
                <div class="flex items-center gap-4 text-base-content/50 text-sm shrink-0">
                  <.log_cost log={log} />
                  <span :if={Map.get(log, :latency_ms)} class="font-mono">{log.latency_ms}ms</span>
                  <span class="font-mono text-xs">{format_time(log.inserted_at)}</span>
                </div>
              </div>
              <div
                :if={last_message_preview(log)}
                class="mt-2 text-xs text-base-content/60 truncate pl-5"
              >
                {last_message_preview(log)}
              </div>
            </a>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # A broken cache prefix produces no error and no latency change — the only
  # symptom is the bill — so the session view has to say it out loud.
  attr :finding, :map, required: true

  defp cache_regression_notice(assigns) do
    assigns =
      assign(assigns, :diff, prefix_diff(assigns.finding.last_hit, assigns.finding.diverged_at))

    ~H"""
    <div class="mb-6 rounded-xl border border-warning/40 bg-warning/5 overflow-hidden">
      <div class="p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold">The prompt cache stopped hitting</h3>
            <p class="text-sm text-base-content/70 mt-1">
              From
              <a href={"#turn-#{@finding.diverged_at.id}"} class="link link-warning font-medium">
                {format_time(@finding.diverged_at.inserted_at)}
              </a>
              onward, {@finding.turns} turns read back the same
              <span class="font-mono">{@finding.pinned_read}</span>
              tokens while the conversation grew by
              <span class="font-mono">{@finding.uncached_growth}</span>
              — input that was re-sent at full price instead of being read back at a tenth of it.
            </p>
          </div>
        </div>

        <details :if={@diff} class="mt-3 group">
          <summary class="cursor-pointer text-sm font-medium text-base-content/70 hover:text-base-content select-none">
            What changed in the cached prefix
          </summary>
          <p class="text-xs text-base-content/50 mt-2">
            The region both requests share, which should have come back byte-identical.
          </p>
          <div class="mt-2 max-h-80 overflow-y-auto rounded-lg bg-base-100 border border-base-300 p-3">
            <.diff_block segments={@diff.segments} mono eq_class="text-base-content/40" />
          </div>
        </details>

        <p :if={!@diff} class="text-xs text-base-content/50 mt-3">
          No prefix diff to show — the request bodies were not recorded, or the shared region is
          unchanged and the breakpoint moved for a reason outside the messages (a changed tool
          list, system prompt, or model).
        </p>
      </div>
    </div>
    """
  end

  defp diverging_turn?(nil, _log), do: false
  defp diverging_turn?(finding, log), do: finding.diverged_at.id == log.id

  # Per-request spend. Plan/subscription traffic bills nothing marginal, so
  # "$0" alone reads like missing data — show the would-have-cost instead.
  attr :log, :map, required: true

  defp log_cost(assigns) do
    actual = decimal_float(Map.get(assigns.log, :estimated_cost_usd))
    list = decimal_float(Map.get(assigns.log, :list_cost_usd))

    assigns =
      cond do
        actual > 0 -> assign(assigns, label: format_usd(actual), plan?: false)
        list > 0 -> assign(assigns, label: "~" <> format_usd(list), plan?: true)
        true -> assign(assigns, label: nil, plan?: false)
      end

    ~H"""
    <span
      :if={@label}
      class={["font-mono", @plan? && "text-base-content/35"]}
      title={@plan? && "Included in plan — cost at pay-as-you-go API rates"}
    >
      {@label}
    </span>
    """
  end

  # The pay-as-you-go figure, shown only when it exceeds what was actually
  # billed (i.e. some of the session ran on a plan/subscription key).
  defp would_be_cost(stats) do
    list = decimal_float(Map.get(stats, :total_list_cost_usd))

    if list > decimal_float(Map.get(stats, :total_cost_usd)), do: list
  end

  defp decimal_float(nil), do: 0.0
  defp decimal_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_float(n) when is_number(n), do: n / 1

  @attribution_labels [
    {"system", "System prompt"},
    {"tools", "Tool definitions"},
    {"history", "History"},
    {"tool_results", "Tool results"},
    {"file_contents", "File contents"}
  ]

  # Non-empty buckets of the session rollup, largest first — same shape the
  # log page renders per request, summed by Logs.session_token_attribution.
  defp attribution_rows(%{"buckets" => buckets, "basis_tokens" => basis})
       when is_integer(basis) and basis > 0 do
    for {key, label} <- @attribution_labels,
        bucket = buckets[key],
        is_map(bucket),
        (bucket["allocated_tokens"] || 0) > 0 do
      tokens = bucket["allocated_tokens"]

      %{
        label: label,
        tokens: tokens,
        pct: round(tokens / basis * 100),
        cached_pct: round((bucket["cached_tokens"] || 0) / tokens * 100),
        by_tool: bucket |> Map.get("by_tool", %{}) |> Enum.sort_by(fn {_t, n} -> -n end)
      }
    end
    |> Enum.sort_by(&(-&1.tokens))
  end

  defp attribution_rows(_rollup), do: []

  defp load_data(socket) do
    router = socket.assigns.router
    session_id = socket.assigns.session_id

    stats = Logs.session_stats(router, session_id)
    logs = Logs.list_logs_by_session(router, session_id, limit: 100)

    session_name =
      case logs do
        [first | _] -> first.session_name
        _ -> nil
      end

    socket
    |> assign(:stats, stats)
    |> assign(:logs, logs)
    |> assign(:session_name, session_name)
    |> assign(:cache_regression, cache_regression(logs))
    |> assign(:latency_percentiles, latency_percentiles(logs))
    |> assign(:token_attribution, Logs.session_token_attribution(router, session_id))
  end

  # A session is small enough that a per-session DB percentile query is
  # overkill — the logs are already loaded for the timeline, so the
  # percentiles are computed from those in memory (nearest-rank method).
  defp latency_percentiles(logs) do
    latencies =
      logs
      |> Enum.map(&Map.get(&1, :latency_ms))
      |> Enum.filter(&is_number/1)
      |> Enum.sort()

    %{p50: percentile(latencies, 0.50), p95: percentile(latencies, 0.95)}
  end

  defp percentile([], _p), do: nil

  defp percentile(sorted, p) do
    count = length(sorted)
    index = max(0, ceil(p * count) - 1)
    Enum.at(sorted, index)
  end

  # The classifier names the turn; the view also needs the turn *before* it —
  # the last one that still read its prefix back — to have something to diff
  # against.
  defp cache_regression(logs) do
    case CacheRegression.classify(logs) do
      {:regressed, finding} ->
        Map.put(finding, :last_hit, previous_log(logs, finding.diverged_at))

      _ ->
        nil
    end
  end

  defp previous_log(logs, %{id: id}) do
    logs
    |> Enum.take_while(&(&1.id != id))
    |> List.last()
  end

  # What the two requests share is supposed to be byte-stable: the second is an
  # extension of the first, so everything up to the first's length should come
  # back unchanged. Rendering only that region is the diagnosis — anything
  # highlighted here is what moved the breakpoint.
  defp prefix_diff(nil, _diverged), do: nil

  defp prefix_diff(last_hit, diverged) do
    before = render_prefix(last_hit)
    unchanged_length = before |> String.split("\n") |> length()
    after_ = diverged |> render_prefix() |> take_lines(unchanged_length)

    case TextDiff.diff(before, after_, granularity: :line) do
      %{stats: %{ins: 0, del: 0}} -> nil
      diff -> diff
    end
  end

  defp take_lines(text, count) do
    text |> String.split("\n") |> Enum.take(count) |> Enum.join("\n")
  end

  # System prompt and messages in wire order — the prefix the cache is keyed
  # on. Tool definitions render ahead of both upstream, but they are not stored
  # per turn, so a change there shows up as an unexplained diff rather than a
  # wrong one.
  defp render_prefix(log) do
    {messages, params} = MessageNormalizer.parse_request_body(log.request_body)

    system =
      case params["system"] do
        text when is_binary(text) -> ["system: " <> text]
        _ -> []
      end

    (system ++ Enum.map(messages, &render_message/1)) |> Enum.join("\n")
  end

  defp render_message(%{role: role, content: content} = message) do
    tools =
      case message[:tool_calls] do
        calls when is_list(calls) and calls != [] -> " " <> Jason.encode!(calls)
        _ -> ""
      end

    "#{role}: #{content}#{tools}"
  end

  defp format_latency(nil), do: "0"
  defp format_latency(%Decimal{} = ms), do: ms |> Decimal.round(0) |> Decimal.to_integer()
  defp format_latency(ms), do: round(ms)

  defp status_badge_class("success"), do: "bg-success/20 text-success"
  defp status_badge_class("fallback"), do: "bg-warning/20 text-warning"
  defp status_badge_class("error"), do: "bg-error/20 text-error"
  defp status_badge_class("pending"), do: "bg-info/20 text-info"
  defp status_badge_class(_), do: "bg-base-300 text-base-content/60"

  defp last_message_preview(log) do
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

  defp truncate_preview(content) do
    if String.length(content) > 120 do
      String.slice(content, 0, 120) <> "..."
    else
      content
    end
  end

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")
end
