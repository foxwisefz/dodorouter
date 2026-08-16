defmodule DodoRouterWeb.LogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Evaluations
  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Logs.Provenance
  alias DodoRouter.Proxy.Adapter.Registry
  alias DodoRouter.Proxy.Fidelity
  alias DodoRouter.Usage
  alias DodoRouterWeb.Components.Charts
  alias DodoRouterWeb.MarkdownRenderer

  import DodoRouterWeb.PromptComponents

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    # Try by primary key first, then by request_id (for live stream links)
    log =
      case Logs.get_log(socket.assigns.current_user, id) do
        nil -> Logs.get_log_by_request_id!(socket.assigns.current_user, id)
        log -> log
      end

    highlight_index = parse_message_param(params["message"])

    {req_messages, req_params} = MessageNormalizer.parse_request_body(log.request_body)

    req_messages =
      log
      |> annotate_provenance(socket.assigns.current_user, req_messages)
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        message
        |> Map.put(:abs_index, index)
        |> Map.put(:highlighted, index == highlight_index)
      end)

    resp_message =
      case MessageNormalizer.parse_response_body(log.response_body) do
        nil ->
          nil

        message ->
          # the response bubble's producer is this log itself — mirrors the
          # provenance chips on attributed history messages
          Map.put(message, :producer, %{
            provider: log.final_provider,
            model: log.final_model,
            log_id: log.id
          })
      end

    req_headers = parse_headers(log.request_headers)
    resp_headers = parse_headers(log.response_headers)
    available_tools = MessageNormalizer.extract_tools(req_params)
    fidelity_changes = Enum.reject(log.fidelity_changes || [], &Fidelity.hidden?/1)

    socket =
      socket
      |> assign(:page_title, "Request #{String.slice(log.request_id, 0, 8)}...")
      |> assign(:log, log)
      |> assign(:req_messages, req_messages)
      |> assign(:req_params, req_params)
      |> assign(:resp_message, resp_message)
      |> assign(:req_headers, req_headers)
      |> assign(:resp_headers, resp_headers)
      |> assign(:available_tools, available_tools)
      |> assign(:selected_tool, nil)
      |> assign(:active_tab, "conversation")
      |> assign(:expanded_messages, MapSet.new())
      |> assign(:truncation_flags, log.truncation_flags || [])
      |> assign(:fidelity_changes, fidelity_changes)
      |> assign(:trace, build_trace(log, fidelity_changes))
      |> assign(:client_format, client_format(log, req_headers))
      |> assign(:finish_reason, extract_finish_reason(log.response_body))
      |> assign(:evaluations, Evaluations.list_for_log(socket.assigns.current_user, log.id))
      |> assign(:replay_count, Logs.replay_counts([log.id]) |> Map.get(log.id, 0))
      |> assign(:baselines, Logs.request_baselines(log.router_id))

    {:ok, socket}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("show_tool", %{"name" => name}, socket) do
    tool = Enum.find(socket.assigns.available_tools, &(&1.name == name))
    {:noreply, assign(socket, :selected_tool, tool)}
  end

  def handle_event("hide_tool", _params, socket) do
    {:noreply, assign(socket, :selected_tool, nil)}
  end

  def handle_event("toggle_message", %{"index" => idx}, socket) do
    idx =
      case Integer.parse(idx) do
        {int, ""} -> int
        _ -> idx
      end

    expanded =
      if MapSet.member?(socket.assigns.expanded_messages, idx) do
        MapSet.delete(socket.assigns.expanded_messages, idx)
      else
        MapSet.put(socket.assigns.expanded_messages, idx)
      end

    {:noreply, assign(socket, :expanded_messages, expanded)}
  end

  def handle_event("toggle_favorite", _params, socket) do
    case Logs.toggle_favorite(socket.assigns.current_user, socket.assigns.log.id) do
      {:ok, log} ->
        {:noreply, assign(socket, :log, log)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update favorite")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :return_to, params["return_to"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <!-- Header -->
        <div class="flex items-center gap-4 mb-6">
          <.link navigate={@return_to || ~p"/logs"} class="btn btn-ghost btn-sm btn-square">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
          </.link>
          <div class="flex-1">
            <h1 class="text-2xl font-bold">Request Details</h1>
            <code class="text-sm text-base-content/60">{@log.request_id}</code>
          </div>
          <details id="log-evaluations" class="group relative">
            <summary class="btn btn-ghost btn-sm list-none gap-2 cursor-pointer">
              <.icon name="hero-beaker" class="size-4" /> Evaluations
              <span
                :if={@evaluations != []}
                class="rounded-full bg-primary/10 px-1.5 text-[10px] font-semibold text-primary"
              >
                {length(@evaluations)}
              </span>
              <.icon
                name="hero-chevron-down"
                class="size-3.5 transition-transform group-open:rotate-180"
              />
            </summary>
            <div class="absolute right-0 z-50 mt-2 w-72 overflow-hidden rounded-xl border border-base-300/70 bg-base-100 shadow-xl">
              <div class="px-3 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
                Evaluations for this log
              </div>
              <div :if={@evaluations == []} class="px-3 py-3 text-sm text-base-content/45">
                No evaluations yet
              </div>
              <.link
                :for={evaluation <- @evaluations}
                navigate={~p"/evals/#{evaluation.id}"}
                class="flex items-center gap-3 px-3 py-2.5 text-sm transition hover:bg-base-200"
                title={"Open evaluation: #{evaluation.name}"}
              >
                <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary">
                  <.icon name="hero-chart-bar-square" class="size-4" />
                </span>
                <span class="min-w-0">
                  <span class="block truncate font-medium">{evaluation.name}</span><span class="block text-xs capitalize text-base-content/40">{evaluation.benchmark_status}</span>
                </span>
              </.link>
              <div class="border-t border-base-300/60 p-2">
                <.link
                  id="create-eval-button"
                  navigate={~p"/logs/#{@log.id}/evals/new"}
                  class="flex items-center gap-2 rounded-lg px-2.5 py-2 text-sm font-medium text-primary transition hover:bg-primary/5"
                >
                  <.icon name="hero-plus" class="size-4" /> Create new evaluation
                </.link>
              </div>
            </div>
          </details>
          <.link
            :if={@log.replayed_from_id}
            id="replay-of-link"
            navigate={~p"/logs/#{@log.replayed_from_id}/replay?replay=#{@log.id}"}
            class="btn btn-ghost btn-sm gap-2"
            title="This log was produced by a replay — open the side-by-side comparison with its original"
          >
            <.icon name="hero-scale" class="w-4 h-4" /> Compare with original
          </.link>
          <.link
            :if={!@log.replayed_from_id}
            id="replay-button"
            navigate={~p"/logs/#{@log.id}/replay"}
            class="btn btn-primary btn-soft btn-sm gap-2"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Replay
            <span :if={@replay_count > 0} class="badge badge-sm">{@replay_count}</span>
          </.link>
          <button
            type="button"
            id="favorite-button"
            phx-click="toggle_favorite"
            data-favorited={to_string(@log.favorite)}
            class={[
              "btn btn-ghost btn-sm btn-square",
              @log.favorite && "text-warning"
            ]}
            title={if @log.favorite, do: "Unfavorite", else: "Favorite"}
          >
            <.icon
              name={if @log.favorite, do: "hero-star-solid", else: "hero-star"}
              class="w-5 h-5"
            />
          </button>
        </div>
        
    <!-- Split pane -->
        <div class="flex-1 flex flex-col lg:flex-row overflow-hidden">
          <!-- Left sidebar -->
          <div class="w-full lg:w-52 shrink-0 max-h-44 lg:max-h-none border-b lg:border-b-0 lg:border-r border-base-300/30 overflow-y-auto p-3 space-y-4 lg:space-y-4 bg-base-100/30 grid grid-cols-2 gap-x-4 lg:block">
            <%!-- Grouped by the task a reader has, not by where each field
               comes from (status/timing/model/session/usage/routing were six
               boxes ordered by data source). "What happened" answers the
               debugging question first: did it work, what answered it, how
               long did it take, and which hop in the chain was where the
               time went — read top to bottom in that order. --%>
            
    <!-- Status -->
            <div data-group="what-happened">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Status
              </div>
              <div class="text-lg"><.status_badge status={@log.status} /></div>
              <div
                :if={@finish_reason in ["length", "max_tokens", "model_length", "content_filter"]}
                id="truncation-notice"
                class="mt-2 flex items-start gap-1.5 rounded-lg bg-warning/10 px-2 py-1.5 text-[11px] leading-snug text-warning"
                title={"finish_reason: #{@finish_reason}"}
              >
                <.icon name="hero-scissors" class="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  {if @finish_reason == "content_filter",
                    do: "Response cut off by the provider's content filter",
                    else: "Response truncated — hit the max_tokens limit"}
                </span>
              </div>
            </div>
            
    <!-- Model -->
            <div data-group="what-happened">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                {if @log.status == "error", do: "Model (last attempted)", else: "Model"}
              </div>
              <div class={[
                "text-sm font-mono",
                @log.status == "error" && "text-base-content/50 line-through decoration-error/40"
              ]}>
                {@log.final_model}
              </div>
              <div class="flex items-center gap-1.5 mt-1">
                <div class="w-3.5 h-3.5 rounded flex items-center justify-center shrink-0 bg-base-200">
                  <.provider_logo slug={normalize_slug(@log.final_provider)} class="w-2.5 h-2.5" />
                </div>
                <div class="text-xs text-base-content/60">{@log.final_provider}</div>
              </div>
              <div
                :if={requested_model(@req_params, @log)}
                class="mt-1 text-[11px] text-base-content/40"
                title="Model named by the client; the routing chain decided what actually served it"
              >
                requested: <span class="font-mono">{requested_model(@req_params, @log)}</span>
              </div>
              <%= if effort = attempt_effort(List.last(@log.attempted_steps)) do %>
                <div class="mt-1.5">
                  <span
                    class="px-1.5 py-0.5 rounded text-xs bg-accent/20 text-accent"
                    title="Reasoning effort configured on the routing step at request time"
                  >
                    effort: {effort}
                  </span>
                </div>
              <% end %>
            </div>
            
    <!-- Timing -->
            <div data-group="what-happened">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Timing
              </div>
              <div class="flex justify-between text-xs mb-1">
                <span class="text-base-content/60">Total</span>
                <span class="font-mono">{fmt_ms(@log.latency_ms)}</span>
              </div>
              <%!-- One stacked bar answers "where did the time go" without
                 mental subtraction. Segments are a non-overlapping partition
                 that always sums to Total by construction: Upload + Wait +
                 Provider processing + Unattributed together equal
                 `provider_time/1` (the sum of every attempted step's own
                 latency), and Overhead is `total - provider_time`. TTFB is
                 deliberately not a segment — it's Upload + Wait, so plotting
                 it too would double-count. "Unattributed" absorbs whatever
                 provider_time isn't explained by upload/wait/proc (retried
                 attempts before the winning one, or old rows missing the
                 finer-grained fields), so old rows still render an honest,
                 if coarser, bar instead of one that silently omits time. --%>
              <Charts.share_bar
                id="timing-bar"
                segments={timing_segments(@log)}
                tip_suffix="of total time"
              />
              <details class="mt-1.5 text-xs">
                <summary class="cursor-pointer text-base-content/60 select-none">
                  Breakdown
                </summary>
                <div class="space-y-1 mt-1.5">
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Provider</span>
                    <span class="font-mono">{fmt_ms(provider_time(@log))}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Overhead</span>
                    <span class="font-mono">{fmt_ms(overhead_time(@log))}</span>
                  </div>
                  <%!-- "Overhead" has no median of its own to compare against
                     (it isn't a stored column); comparing this request's
                     Total against the router's own p50/p95 total latency is
                     the honest basis that's actually queryable. Omitted
                     entirely when the router has no other recent traffic to
                     compare against, rather than comparing a value to
                     itself. --%>
                  <div
                    :if={total_baseline_note(@log, @baselines)}
                    id="overhead-baseline"
                    class="text-[10px] text-base-content/40 -mt-0.5"
                  >
                    {total_baseline_note(@log, @baselines)}
                  </div>
                  <div :if={@log.ttfb_ms} class="flex justify-between">
                    <span class="text-base-content/60">TTFB</span>
                    <span class="font-mono">{fmt_ms(@log.ttfb_ms)}</span>
                  </div>
                  <%!-- Upload/Wait only earn a row when upload actually took time;
                     otherwise Wait just repeats TTFB --%>
                  <div :if={@log.upload_ms && @log.upload_ms > 0} class="flex justify-between">
                    <span class="text-base-content/60">Upload</span>
                    <span class="font-mono">{fmt_ms(@log.upload_ms)}</span>
                  </div>
                  <div
                    :if={@log.ttfb_ms && @log.upload_ms && @log.upload_ms > 0}
                    class="flex justify-between"
                  >
                    <span class="text-base-content/60" title="TTFB minus upload">Wait</span>
                    <span class="font-mono">{fmt_ms(wait_time(@log))}</span>
                  </div>
                  <%= if @log.provider_processing_ms do %>
                    <div class="flex justify-between">
                      <span class="text-base-content/60">Proc</span>
                      <span class="font-mono">{@log.provider_processing_ms}ms</span>
                    </div>
                  <% end %>
                </div>
              </details>
            </div>

            <%= if length(@log.tools_invoked) > 0 do %>
              <div data-group="what-happened">
                <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                  Tools
                </div>
                <div class="flex flex-wrap gap-1">
                  <span
                    :for={tool <- @log.tools_invoked}
                    class="badge badge-secondary badge-sm font-mono"
                  >
                    {tool}
                  </span>
                </div>
              </div>
            <% end %>
            
    <!-- Routing Chain -->
            <div data-group="what-happened">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Routing
              </div>
              <%!-- The slow hop is marked relative to the OTHER hops of this
                 same request (>60% of the summed attempt latencies), not
                 against any router-wide baseline — that's the honest
                 comparison for a single trace, and it needs no query. --%>
              <div class="space-y-1">
                <%= for {attempt, dominant?} <- dominant_hop_flags(@log.attempted_steps) do %>
                  <div
                    phx-click="set_tab"
                    phx-value-tab="trace"
                    role="button"
                    title="Open the trace"
                    data-hop-slow={if dominant?, do: "true"}
                    class={[
                      "flex items-center gap-1.5 text-xs rounded px-1 -mx-1 py-0.5 cursor-pointer hover:bg-secondary/60 transition-colors",
                      dominant? && "bg-warning/10"
                    ]}
                  >
                    <%= if attempt["status"] == "success" do %>
                      <span class="text-success">✓</span>
                    <% else %>
                      <span class="text-error">✗</span>
                    <% end %>
                    <span class="font-medium truncate">{attempt["provider"]}</span>
                    <%= if attempt["provider_key_id"] && attempt["provider_key_slug"] do %>
                      <.link
                        navigate={
                          ~p"/providers?highlight=#{attempt["provider_key_id"]}&provider=#{attempt["provider_key_slug"]}"
                        }
                        class="text-[10px] text-primary hover:underline truncate max-w-[80px]"
                        title={attempt["provider_key_label"]}
                      >
                        {attempt["provider_key_label"]}
                      </.link>
                    <% end %>
                    <span
                      class={[
                        "font-mono ml-auto",
                        if(dominant?, do: "text-warning", else: "text-base-content/40")
                      ]}
                      title={if dominant?, do: "Dominates this request's routing chain"}
                    >
                      {attempt["latency_ms"]}ms
                    </span>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- What it cost: tokens spent, how much of that was cache, and
               the resulting spend against this router's own baseline —
               previously split across "Usage" and left to imply cost was
               just another usage number rather than the thing this box is
               actually for. --%>
            
    <!-- Usage -->
            <div data-group="what-it-cost">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Usage
              </div>
              <div class="space-y-1 text-xs">
                <div class="flex justify-between">
                  <span class="text-base-content/60">Type</span>
                  <span class="text-right"><.call_type_badge type={@log.call_type} /></span>
                </div>
                <%= if @log.prompt_tokens || @log.completion_tokens do %>
                  <div class="flex justify-between">
                    <span
                      class="text-base-content/60"
                      title="Uncached prompt tokens. Cache reads are billed separately at a reduced rate."
                    >
                      Input (new)
                    </span>
                    <span class="font-mono">{new_input(@log)}</span>
                  </div>
                <% else %>
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Tokens</span>
                    <span class="font-mono">{@log.total_tokens || "—"}</span>
                  </div>
                <% end %>
                <%= if @log.cache_read_tokens && @log.cache_read_tokens > 0 do %>
                  <div class="flex justify-between text-success">
                    <span class="flex items-center gap-1">
                      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M13 10V3L4 14h7v7l9-11h-7z"
                        />
                      </svg>
                      Cached
                    </span>
                    <span class="font-mono">
                      {@log.cache_read_tokens}
                      <span class="text-base-content/40">
                        ({cache_pct(@log)})
                      </span>
                    </span>
                  </div>
                <% end %>
                <%= if @log.cache_write_tokens && @log.cache_write_tokens > 0 do %>
                  <div class="flex justify-between text-base-content/40">
                    <span>Cache write</span>
                    <span class="font-mono">{@log.cache_write_tokens}</span>
                  </div>
                <% end %>
                <div :if={@log.completion_tokens} class="flex justify-between">
                  <span class="text-base-content/60">Output</span>
                  <span class="font-mono">{@log.completion_tokens}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/60">Cost</span>
                  <%= if plan_covered?(@log) do %>
                    <span
                      class="text-success"
                      title="Served through a subscription/coding-plan key — no marginal per-token cost. The figure is what the same tokens would cost at pay-as-you-go API list prices."
                    >
                      included in plan
                      <span
                        :if={@log.list_cost_usd && Decimal.gt?(@log.list_cost_usd, 0)}
                        class="font-mono text-base-content/45"
                      >
                        ~${Decimal.round(@log.list_cost_usd, 4)} at API rates
                      </span>
                    </span>
                  <% else %>
                    <span class="font-mono">
                      {if @log.estimated_cost_usd,
                        do: "$#{Decimal.round(@log.estimated_cost_usd, 4)}",
                        else: "-"}
                    </span>
                  <% end %>
                </div>
                <div
                  :if={cost_baseline_note(@log, @baselines)}
                  id="cost-baseline"
                  class="text-[10px] text-base-content/40 text-right -mt-0.5"
                >
                  {cost_baseline_note(@log, @baselines)}
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/60" title="Request payload size">Req size</span>
                  <span class="font-mono">{format_bytes(@log.payload_size_bytes)}</span>
                </div>
                <div :if={@log.idempotency_key} class="flex justify-between gap-2">
                  <span
                    class="text-base-content/60 shrink-0"
                    title="The client asked for exactly-once semantics on this request"
                  >
                    Idempotency key
                  </span>
                  <span class="font-mono break-all text-right">{@log.idempotency_key}</span>
                </div>
                <div :if={@log.idempotent_replay_of_id} class="flex justify-between text-success">
                  <span title="Served from the stored response of an earlier request carrying the same Idempotency-Key — no provider call, no cost">
                    Idempotent replay
                  </span>
                  <.link
                    id="idempotent-replay-link"
                    navigate={~p"/logs/#{@log.idempotent_replay_of_id}"}
                    class="font-mono text-primary hover:underline"
                  >
                    original ↗
                  </.link>
                </div>
              </div>
            </div>

            <%!-- What the input tokens were made of. Shares are pro-rata
               allocations of the billed total (no provider tokenizer is
               public), so the percentages are the trustworthy part. --%>
            <div :if={attribution_rows(@log) != []} data-group="context-breakdown">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Context breakdown
              </div>
              <div id="token-attribution" class="space-y-1 text-xs">
                <div :for={row <- attribution_rows(@log)} class="space-y-0.5">
                  <div class="flex justify-between">
                    <span class="text-base-content/60">{row.label}</span>
                    <span class="font-mono">
                      {row.pct}% <span class="text-base-content/40">· ~{row.tokens}</span>
                      <span
                        :if={row.cached_pct > 0}
                        class="text-success"
                        title="Share of this segment sitting in the cacheable prefix"
                      >
                        {row.cached_pct}% cached
                      </span>
                    </span>
                  </div>
                  <div class="h-1 rounded-full bg-base-300/60 overflow-hidden">
                    <div class="h-full rounded-full bg-primary/70" style={"width: #{row.pct}%"}></div>
                  </div>
                  <div
                    :if={row.by_tool != []}
                    class="text-[10px] text-base-content/45 text-right"
                  >
                    {Enum.map_join(row.by_tool, " · ", fn {tool, tokens} -> "#{tool} ~#{tokens}" end)}
                  </div>
                </div>
              </div>
            </div>

            <%!-- Where it came from: the session this request belongs to
               (and, via that link, the router) — everything about the
               client side of the request rather than what the provider did
               with it. --%>
            
    <!-- Session -->
            <div :if={@log.session_id} data-group="where-it-came-from">
              <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                Session
              </div>
              <.link
                navigate={~p"/routers/#{@log.router_id}/sessions/#{@log.session_id}"}
                class="text-xs font-mono text-primary hover:underline break-all"
                title="All requests in this session"
              >
                {@log.session_id}
              </.link>
            </div>
          </div>
          
    <!-- Right content -->
          <div class="flex-1 overflow-hidden flex flex-col">
            <!-- Tabs -->
            <div class="border-b border-base-300/30 px-4 pt-2">
              <%!-- Two modes, not four peers. "Conversation" is a different axis —
                 what was *said*. "Trace" is the wire: client, us, each provider
                 we tried, and back. The three tabs it replaces were single hops
                 lifted out of that sequence and stripped of their position. --%>
              <div class="flex gap-1 overflow-x-auto whitespace-nowrap" role="tablist">
                <button
                  type="button"
                  phx-click="set_tab"
                  phx-value-tab="conversation"
                  role="tab"
                  aria-selected={@active_tab == "conversation"}
                  class={[
                    "px-3 py-1.5 text-xs font-medium rounded-t-lg transition",
                    @active_tab == "conversation" &&
                      "bg-base-100 text-base-content border-t border-x border-base-300/30 -mb-px",
                    @active_tab != "conversation" &&
                      "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
                  ]}
                >
                  Conversation
                </button>
                <button
                  type="button"
                  phx-click="set_tab"
                  phx-value-tab="trace"
                  role="tab"
                  aria-selected={@active_tab == "trace"}
                  class={[
                    "px-3 py-1.5 text-xs font-medium rounded-t-lg transition flex items-center gap-1.5",
                    @active_tab == "trace" &&
                      "bg-base-100 text-base-content border-t border-x border-base-300/30 -mb-px",
                    @active_tab != "trace" &&
                      "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
                  ]}
                >
                  Trace
                  <span :if={@fidelity_changes != []} class="badge badge-xs badge-ghost">
                    {length(@fidelity_changes)}
                  </span>
                </button>
              </div>
            </div>
            
    <!-- Tab panels -->
            <div class="flex-1 overflow-y-auto">
              <%= if @active_tab == "conversation" do %>
                <div class="p-4">
                  <div
                    :if={@log.status == "error"}
                    id="request-failure-panel"
                    class="mb-4 rounded-xl border border-error/30 bg-error/5 p-4"
                  >
                    <div class="flex items-center gap-2 mb-1.5">
                      <.icon name="hero-x-circle" class="size-5 text-error shrink-0" />
                      <h3 class="font-semibold text-error">
                        This request failed — no provider returned a response
                      </h3>
                    </div>
                    <p :if={client_error_message(@log)} class="text-sm text-base-content/80 mb-3">
                      Returned to your client:
                      <span class="font-mono">{client_error_message(@log)}</span>
                    </p>
                    <div class="space-y-1">
                      <div
                        :for={attempt <- @log.attempted_steps || []}
                        class="flex items-center gap-2 text-sm font-mono"
                      >
                        <.icon name="hero-x-mark" class="size-3.5 text-error shrink-0" />
                        <span class="text-base-content/80">
                          {attempt["provider"]}/{attempt["model"]}
                        </span>
                        <span class="text-error/80">
                          {attempt["http_status"]} {attempt["error"]}
                        </span>
                        <span class="text-base-content/50 text-xs truncate">
                          {attempt_error_message(attempt)}
                        </span>
                        <span class="ml-auto text-base-content/40 text-xs shrink-0">
                          {attempt["latency_ms"]}ms
                        </span>
                      </div>
                    </div>
                    <button
                      phx-click="set_tab"
                      phx-value-tab="trace"
                      class="mt-3 text-sm text-error font-medium hover:underline"
                    >
                      Full trace with headers and bodies →
                    </button>
                  </div>
                  <%!-- "We changed nothing" is the product's central claim, so silence is the
     wrong way to say it. A clean request states it outright instead of
     rendering blank space where the panel would be. --%>
                  <%= if @fidelity_changes == [] do %>
                    <div
                      id="fidelity-clean"
                      class="mb-4 flex items-center gap-2 rounded-lg border border-success/30 bg-success/5 px-4 py-2.5"
                    >
                      <.icon name="hero-check-circle" class="w-4 h-4 text-success shrink-0" />
                      <span class="text-sm">
                        <span class="font-semibold">Passed through unchanged</span>
                        <span class="text-base-content/60">
                          — {passthrough_summary(@log)}
                        </span>
                      </span>
                    </div>
                  <% end %>
                  <%!-- The edits themselves live on the Trace, hung off the hop that
                     made them. A floating table here could only point at a step
                     three clicks away, which is what it used to do. --%>
                  <%= if length(@fidelity_changes) > 0 do %>
                    <button
                      type="button"
                      id="fidelity-summary"
                      phx-click="set_tab"
                      phx-value-tab="trace"
                      class="mb-4 w-full flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-4 py-2.5 text-left hover:bg-base-200/60 transition-colors"
                    >
                      <.icon name="hero-scissors" class="w-4 h-4 text-base-content/50 shrink-0" />
                      <span class="text-sm font-semibold">What the proxy changed</span>
                      <span class="badge badge-sm badge-ghost">{length(@fidelity_changes)}</span>
                      <span class="ml-auto text-xs text-primary">see it on the trace →</span>
                    </button>
                  <% end %>
                  <%= if length(@truncation_flags) > 0 do %>
                    <div class="alert alert-warning mb-4">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="h-5 w-5 shrink-0"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                        />
                      </svg>
                      <div>
                        <span class="font-semibold">Content truncated</span>
                        <span class="text-sm block">
                          This request had large payloads that were truncated before storage.
                        </span>
                      </div>
                    </div>
                  <% end %>
                  <div
                    :if={length(@req_messages) > 3}
                    id="scroll-rail"
                    phx-hook="ScrollRail"
                    class="hidden lg:flex fixed right-3 top-1/2 -translate-y-1/2 z-30 flex-col gap-1.5"
                  >
                    <a
                      :for={bucket <- rail_buckets(@req_messages)}
                      href={"#message-#{bucket.from}"}
                      id={"rail-msg-#{bucket.from}"}
                      data-from={bucket.from}
                      data-to={bucket.to}
                      class={[
                        "block w-4 h-1 rounded-full transition-all hover:scale-x-150 hover:bg-primary",
                        bucket_color(bucket)
                      ]}
                      title={bucket_title(bucket)}
                    >
                    </a>
                  </div>
                  <.conversation
                    messages={@req_messages}
                    response={@resp_message}
                    model={@log.final_model}
                    provider={@log.final_provider}
                    tools={@available_tools}
                    cache_read_tokens={@log.cache_read_tokens}
                    cache_write_tokens={@log.cache_write_tokens}
                    replay_base={
                      if(@log.replayed_from_id, do: nil, else: ~p"/logs/#{@log.id}/replay")
                    }
                  />
                </div>
              <% end %>

              <%!-- The Trace: one node per hop, in wire order, with everything the
                 proxy removed or rewrote hanging off the edge that produced it.
                 The tabs this replaced modelled the hops as unordered peers, so
                 a fallback chain had nowhere to render and the fidelity panel's
                 "Step" column pointed at a tab three clicks away. --%>
              <%= if @active_tab == "trace" do %>
                <div class="p-4">
                  <div class="text-sm text-base-content/60 mb-4">{trace_summary(@log)}</div>
                  <div>
                    <%= for hop <- @trace do %>
                      <.trace_edge :if={hop.edge} hop={hop} />
                      <%= case hop.kind do %>
                        <% :client_request -> %>
                          <.trace_client_request
                            format={@client_format}
                            req_headers={@req_headers}
                          />
                        <% :attempt -> %>
                          <.trace_attempt hop={hop} />
                        <% :client_response -> %>
                          <.trace_client_response
                            log={@log}
                            format={@client_format}
                            resp_headers={@resp_headers}
                          />
                      <% end %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <.modal
          :if={@selected_tool}
          id="tool-modal"
          show
          on_cancel={JS.push("hide_tool")}
        >
          <div class="flex items-center gap-2 mb-4">
            <.icon name={tool_icon(@selected_tool.name)} class="w-5 h-5 text-base-content/60" />
            <h3 class="text-lg font-semibold font-mono">{@selected_tool.name}</h3>
          </div>

          <%= if @selected_tool.description && String.length(@selected_tool.description) > 0 do %>
            <div class="mb-4">
              <div class="flex items-center gap-2 mb-2 text-sm text-base-content/40 font-semibold">
                <.icon name="hero-document-text" class="w-4 h-4" />
                <span>Description</span>
              </div>
              <MarkdownRenderer.render content={@selected_tool.description} />
            </div>
          <% end %>

          <%= if @selected_tool.parameters != %{} do %>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-2">
              Parameters
            </div>
            <.json_panel
              id="tool-parameters"
              content={Jason.encode!(@selected_tool.parameters, pretty: true)}
              copy_id="tool-parameters-copy"
              max_height="max-h-96"
            />
          <% end %>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  defp parse_message_param(nil), do: nil

  defp parse_message_param(value) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 -> index
      _other -> nil
    end
  end

  # A dash per message overflows the viewport on long conversations, so the
  # rail caps at @rail_max_dashes and each dash represents a message range
  # (single-message buckets degenerate to the exact per-message rail)
  @rail_max_dashes 48

  defp rail_buckets(messages) do
    chunk_size = max(1, ceil(length(messages) / @rail_max_dashes))

    messages
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(fn group ->
      %{from: hd(group).abs_index, to: List.last(group).abs_index, messages: group}
    end)
  end

  defp bucket_color(%{messages: [message]}), do: rail_color(message)

  defp bucket_color(%{messages: messages}) do
    cond do
      Enum.any?(messages, &Map.get(&1, :highlighted)) -> "bg-info"
      Enum.any?(messages, &(&1.role == "user")) -> "bg-primary/60"
      true -> "bg-base-content/25"
    end
  end

  defp bucket_title(%{messages: [message]}), do: rail_title(message)

  defp bucket_title(%{from: from, to: to, messages: messages}) do
    user_count = Enum.count(messages, &(&1.role == "user"))
    "##{from + 1}–##{to + 1} · #{user_count} user"
  end

  defp rail_color(%{highlighted: true}), do: "bg-info"
  defp rail_color(%{role: "user"}), do: "bg-primary/60"
  defp rail_color(%{role: "assistant"}), do: "bg-base-content/25"
  defp rail_color(_message), do: "bg-base-content/10"

  defp rail_title(message) do
    preview =
      case message.content do
        content when is_binary(content) and content != "" ->
          " · " <> String.slice(content, 0, 60)

        _other ->
          ""
      end

    "##{message.abs_index + 1} · #{message.role}" <> preview
  end

  defp annotate_provenance(%{session_id: nil}, _user, messages), do: messages

  defp annotate_provenance(log, user, messages) do
    siblings = Logs.list_session_responses(user, log.session_id)
    Provenance.annotate(messages, siblings)
  end

  # The finish_reason of the first choice, so truncated or filtered responses
  # are visible even though the request itself counts as a success.
  defp extract_finish_reason(nil), do: nil

  defp extract_finish_reason(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} -> reason
      {:ok, %{"stop_reason" => reason}} -> reason
      _ -> nil
    end
  end

  # Traffic served through a subscription or coding-plan key has no marginal
  # per-token cost; "$0.0000" there reads like broken billing.
  defp plan_covered?(log) do
    zero_cost? = log.estimated_cost_usd && Decimal.eq?(log.estimated_cost_usd, 0)

    key_slug =
      case List.last(log.attempted_steps || []) do
        %{"provider_key_slug" => slug} -> slug
        _ -> nil
      end

    provider =
      case List.last(log.attempted_steps || []) do
        %{"provider" => p} -> p
        _ -> nil
      end

    !!(zero_cost? && key_slug && key_slug != provider)
  end

  defp requested_model(req_params, log) do
    case req_params do
      %{"model" => model} when is_binary(model) and model != "" ->
        if model != log.final_model, do: model

      _ ->
        nil
    end
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "badge-success"
        "fallback" -> "badge-warning"
        "error" -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"badge #{@class}"}>{@status}</span>
    """
  end

  defp call_type_badge(assigns) do
    class =
      case assigns.type do
        "tool_call" -> "badge-secondary"
        "tool_enabled_completion" -> "badge-primary"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, label: call_type_name(assigns.type), class: class)

    ~H"""
    <span class={"badge #{@class}"}>{@label}</span>
    """
  end

  defp client_error_message(log) do
    with body when is_binary(body) <- log.response_body,
         {:ok, %{"error" => err}} <- Jason.decode(body) do
      err["message"] || err["type"]
    else
      _ -> nil
    end
  end

  # Names the provider that answered, because "unchanged" is a claim about a
  # specific hop: the same request can pass through untouched on an Anthropic
  # step and lose fields on an OpenAI-family fallback.
  defp passthrough_summary(log) do
    case log.final_provider do
      nil -> "every header and field you sent reached the provider"
      provider -> "every header and field you sent reached #{provider}"
    end
  end

  defp fidelity_channel_label("request_header"), do: "Request header"
  defp fidelity_channel_label("request_body"), do: "Request field"
  defp fidelity_channel_label("response_body"), do: "Response field"
  defp fidelity_channel_label(other), do: other

  # A proxied request is a sequence — client, us, each provider we tried, back
  # to the client — so the page renders it as one. Every recorded change carries
  # the step that produced it, which means each edit can hang off the edge it
  # belongs to instead of a table pointing at a step elsewhere in the UI.
  defp build_trace(log, changes) do
    attempts = log.attempted_steps || []

    request_changes = Enum.filter(changes, &(&1["channel"] in ["request_header", "request_body"]))
    response_changes = Enum.filter(changes, &(&1["channel"] == "response_body"))

    # Ingress conversions run before any step exists, so their losses belong to
    # the client -> proxy hop rather than to any provider.
    pre_routing = Enum.filter(request_changes, &is_nil(&1["step"]))

    # `request_body` on an attempt is `state.request` — one request-level
    # artifact copied onto every attempt in the chain. It belongs on the edge
    # where the normalization actually happens, next to the fidelity rows that
    # say what the normalization cost: here is what we turned your request
    # into, and here is what that cost you.
    normalized = normalized_request(log, attempts)

    attempt_hops =
      attempts
      |> Enum.with_index()
      |> Enum.map(fn {attempt, index} ->
        own = Enum.filter(request_changes, &(&1["step"] == (attempt["position"] || index)))
        edge_changes = if index == 0, do: pre_routing ++ own, else: own

        %{
          kind: :attempt,
          key: "attempt-#{index}",
          index: index,
          attempt: attempt,
          # Only when this attempt's request genuinely is not the one on the
          # edge: a midstream fallback rebuilds it with the partial response the
          # previous provider already streamed, and hoisting the shared copy
          # must not hide the one case where it moved.
          request_body: divergent_request(attempt, attempts, index),
          edge: %{
            label: if(index == 0, do: nil, else: "fell back"),
            changes: edge_changes,
            normalized_request: if(index == 0, do: normalized),
            # Stated once, on the first hop, because "unchanged" is a claim
            # about the whole journey — not about one edge that happens to be
            # quiet while another lost a field.
            clean_summary: if(index == 0 and changes == [], do: passthrough_summary(log))
          }
        }
      end)

    orphaned = if attempts == [], do: pre_routing, else: []

    client_response = %{
      kind: :client_response,
      key: "client-response",
      index: length(attempts),
      attempt: List.last(attempts),
      request_body: nil,
      edge: %{
        label: nil,
        changes: orphaned ++ response_changes,
        normalized_request: if(attempts == [], do: normalized),
        clean_summary: if(attempts == [] and changes == [], do: passthrough_summary(log))
      }
    }

    client_request = %{
      kind: :client_request,
      key: "client-request",
      index: 0,
      attempt: nil,
      request_body: nil,
      edge: nil
    }

    [client_request] ++ attempt_hops ++ [client_response]
  end

  defp normalized_request(log, [first | _rest]), do: first["request_body"] || log.request_body
  defp normalized_request(log, _no_attempts), do: log.request_body

  # Compared against the *first attempt's* copy rather than the log's, so a
  # difference in how the two were truncated cannot masquerade as a request
  # that actually changed between hops.
  defp divergent_request(_attempt, _attempts, 0), do: nil

  defp divergent_request(attempt, attempts, _index) do
    baseline = List.first(attempts)["request_body"]
    own = attempt["request_body"]

    if own && baseline && own != baseline, do: own
  end

  defp trace_summary(log) do
    count = length(log.attempted_steps || [])

    cond do
      log.status == "error" ->
        "All #{count} providers failed — every hop below, with what actually went over the wire."

      count <= 1 ->
        "One hop — served on the first attempt."

      true ->
        "Fell back through #{count} providers before one answered."
    end
  end

  # Nothing on the row states the client's format outright: their request body
  # is not stored, and the logged response body is the proxy's OpenAI-shaped IR
  # rather than the bytes the egress wrote — reading it alone labels every
  # Anthropic client "openai", which is the mislabeling this view exists to fix.
  # The headers the client actually sent are theirs and do carry the marker;
  # the IR's shape is only the fallback, and nil is a fine answer.
  defp client_format(log, headers) do
    names = for {key, _value} <- headers || [], do: String.downcase(key)

    if "anthropic-version" in names or "anthropic-beta" in names do
      "anthropic"
    else
      case Jason.decode(log.response_body || "") do
        {:ok, %{"output" => _}} -> "responses"
        {:ok, %{"choices" => _}} -> "openai"
        {:ok, %{"type" => type}} when type in ["message", "error"] -> "anthropic"
        _undeterminable -> nil
      end
    end
  end

  attr :hop, :map, required: true

  defp trace_edge(assigns) do
    ~H"""
    <div
      id={"trace-edge-#{@hop.key}"}
      class="relative ml-[8px] border-l-2 border-dashed border-base-300/80 pl-7 py-3 space-y-2"
    >
      <div :if={@hop.edge.label} class="flex items-center gap-1.5 text-xs font-medium text-warning">
        <.icon name="hero-arrow-uturn-down" class="size-3.5 shrink-0" />
        {@hop.edge.label}
      </div>
      <div :if={@hop.edge.clean_summary} class="flex items-start gap-2 text-xs text-success">
        <.icon name="hero-check-circle" class="size-4 shrink-0 mt-px" />
        <span class="flex flex-wrap items-baseline gap-x-1">
          <span class="font-semibold">Passed through unchanged</span>
          <span class="text-base-content/60">— {@hop.edge.clean_summary}</span>
        </span>
      </div>
      <div
        :if={@hop.edge.changes != []}
        class="flex items-center gap-1.5 text-xs font-medium text-base-content/70"
      >
        <.icon name="hero-scissors" class="size-3.5 shrink-0" />
        we changed {change_count(@hop.edge.changes)}
      </div>
      <div
        :for={{change, position} <- Enum.with_index(@hop.edge.changes)}
        class="rounded-lg border border-base-300/70 bg-base-200/40 px-3 py-2 text-xs space-y-1"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class={[
            "badge badge-xs",
            if(change["action"] == "rewritten", do: "badge-info", else: "badge-ghost")
          ]}>
            {change["action"]}
          </span>
          <span class="text-base-content/50">{fidelity_channel_label(change["channel"])}</span>
          <span class="font-mono font-medium break-all">{change["name"]}</span>
        </div>
        <div class="text-base-content/60">{Fidelity.explain(change["reason"])}</div>
        <div :if={change["detail"]} class="text-base-content/40">{change["detail"]}</div>
        <%!-- The client's original body is not stored, so this value is the only
             surviving record of what they asked for. Collapsed by default: a
             dropped field can be one of the big ones. --%>
        <.trace_toggle
          :if={change["value"]}
          id={"trace-value-#{@hop.key}-#{position}"}
          label="What you sent"
          meta={payload_size(change["value"])}
        >
          <pre class="max-h-48 overflow-auto rounded bg-base-300/40 p-2 font-mono whitespace-pre-wrap break-all"><code>{change["value"]}</code></pre>
        </.trace_toggle>
      </div>
      <%!-- The normalization happens on this edge, so its output belongs here
           next to what it cost — one request-level artifact, stated once,
           rather than a copy inside every attempt node. --%>
      <.trace_toggle
        :if={@hop.edge.normalized_request}
        id="trace-normalized-request"
        label="Normalized request — what we turned yours into"
        meta={payload_size(@hop.edge.normalized_request)}
      >
        <.json_panel
          id="trace-normalized"
          content={format_json(@hop.edge.normalized_request)}
          copy_id="copy-normalized-request"
        />
      </.trace_toggle>
    </div>
    """
  end

  attr :format, :string, default: nil
  attr :req_headers, :list, default: nil

  defp trace_client_request(assigns) do
    ~H"""
    <div id="trace-node-client-request" class="relative pl-7">
      <span class="absolute left-0 top-1 size-[18px] rounded-full border-2 border-primary bg-base-100">
      </span>
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm font-semibold">You sent</span>
        <span
          :if={@format}
          class="badge badge-sm badge-ghost font-mono"
          title="Inferred from the headers you sent — your request body is not stored"
        >
          {@format} format
        </span>
      </div>
      <%!-- Naming the normalized request "what you sent" is the mislabeling this
           view exists to fix: we never stored the client's body. --%>
      <p class="mt-1 text-xs text-base-content/40">
        Your request body is not stored — what follows is the headers you sent and what we changed.
      </p>
      <div class="mt-1.5">
        <.trace_toggle
          :if={@req_headers}
          id="trace-client-headers"
          label="Headers you sent"
          meta={header_count(@req_headers)}
        >
          <.trace_headers headers={@req_headers} />
        </.trace_toggle>
      </div>
    </div>
    """
  end

  attr :hop, :map, required: true

  defp trace_attempt(assigns) do
    assigns = assign(assigns, :attempt, assigns.hop.attempt)

    ~H"""
    <div id={"trace-node-attempt-#{@hop.index}"} class="relative pl-7">
      <span class={[
        "absolute left-0 top-1 size-[18px] rounded-full border-2 bg-base-100",
        @attempt["status"] == "success" && "border-success",
        @attempt["status"] != "success" && "border-error"
      ]}>
      </span>
      <div class={[
        "border rounded-lg overflow-hidden",
        @attempt["status"] == "success" && "border-success/30",
        @attempt["status"] != "success" && "border-error/30"
      ]}>
        <div class={[
          "px-3 py-2 flex items-center justify-between gap-2 text-xs",
          @attempt["status"] == "success" && "bg-success/5",
          @attempt["status"] != "success" && "bg-error/5"
        ]}>
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold">Attempt {@hop.index + 1}</span>
            <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
              <.provider_logo
                slug={
                  normalize_slug(
                    Registry.to_key_slug(@attempt["provider"], @attempt["plan_type"] || "standard")
                  )
                }
                class="w-3 h-3"
              />
            </div>
            <span class="font-medium">{@attempt["provider"]} / {@attempt["model"]}</span>
            <span :if={@attempt["plan_type"]} class="badge badge-sm">{@attempt["plan_type"]}</span>
            <span
              :if={attempt_effort(@attempt)}
              class="badge badge-sm badge-accent badge-outline"
              title="Reasoning effort"
            >
              effort: {attempt_effort(@attempt)}
            </span>
            <%= if @attempt["status"] == "success" do %>
              <span class="text-success font-medium">✓ Success</span>
            <% else %>
              <span class="text-error font-medium">
                ✗ {@attempt["http_status"]} {@attempt["error"]}
              </span>
            <% end %>
          </div>
          <span class="font-mono text-base-content/60 shrink-0">
            {fmt_ms(@attempt["latency_ms"])}
          </span>
        </div>

        <div class="px-3 py-2.5 text-xs">
          <%!-- Where the request went, as a two-column pair rather than two more
               rows competing with the artifacts below. --%>
          <div class="grid grid-cols-[auto_1fr] items-baseline gap-x-3 gap-y-1">
            <span
              :if={@attempt["endpoint"]}
              class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold"
            >
              Endpoint
            </span>
            <span :if={@attempt["endpoint"]} class="font-mono text-base-content/70 break-all">
              {@attempt["endpoint"]}
            </span>
            <span
              :if={@attempt["provider_key_id"] && @attempt["provider_key_slug"]}
              class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold"
            >
              API Key
            </span>
            <.link
              :if={@attempt["provider_key_id"] && @attempt["provider_key_slug"]}
              navigate={
                ~p"/providers?highlight=#{@attempt["provider_key_id"]}&provider=#{@attempt["provider_key_slug"]}"
              }
              class="font-mono text-primary hover:underline justify-self-start"
            >
              {@attempt["provider_key_label"]}
            </.link>
          </div>

          <%!-- The artifacts are grouped by which way they travelled. Rendered as
               one flat list of identical links, a header dump and a response body
               read as peers, and nothing said which end of the wire each was
               from — the complaint that prompted this grouping. --%>
          <.trace_section icon="hero-arrow-up-tray" label={"Sent to #{@attempt["provider"]}"}>
            <.trace_toggle
              :if={@attempt["outbound_headers"]}
              id={"trace-outbound-headers-#{@hop.index}"}
              label="Headers"
              meta={header_count(@attempt["outbound_headers"])}
            >
              <.trace_headers headers={@attempt["outbound_headers"]} />
            </.trace_toggle>

            <%!-- Only ResponsesAPI records the bytes it sent. Filling the gap with
                 the normalized request would assert those were the bytes on the
                 wire; they were its input, and each adapter rebuilds from it. --%>
            <.trace_toggle
              :if={@attempt["outbound_body"]}
              id={"trace-outbound-body-#{@hop.index}"}
              label="Body — the bytes this provider received"
              meta={payload_size(@attempt["outbound_body"])}
            >
              <.json_panel
                id={"trace-outbound-#{@hop.index}"}
                content={format_json(@attempt["outbound_body"])}
                copy_id={"copy-outbound-body-#{@hop.index}"}
              />
            </.trace_toggle>

            <%!-- Shown only when this attempt's request is not the one on the edge:
                 a midstream fallback rebuilds it with the partial response the
                 previous provider already streamed. --%>
            <.trace_toggle
              :if={@hop.request_body}
              id={"trace-request-body-#{@hop.index}"}
              label="Request rebuilt for this attempt"
              meta={payload_size(@hop.request_body)}
            >
              <p class="mb-1 text-base-content/40">
                It differs from the normalized request on the edge above.
              </p>
              <.json_panel
                id={"trace-rebuilt-#{@hop.index}"}
                content={format_json(@hop.request_body)}
                copy_id={"copy-attempt-request-#{@hop.index}"}
              />
            </.trace_toggle>

            <%!-- Names whichever request this adapter actually built from: on a
                 midstream fallback the normalized one on the edge is not it. --%>
            <p
              :if={is_nil(@attempt["outbound_body"])}
              class="flex items-start gap-2 py-1.5 text-base-content/40"
            >
              <.icon name="hero-information-circle" class="size-3.5 shrink-0 mt-px" />
              <span>
                Body not recorded — this adapter does not keep the bytes it sent. {if @hop.request_body,
                  do: "The request rebuilt above is what it built them from.",
                  else: "The normalized request above is what it built them from."}
              </span>
            </p>
          </.trace_section>

          <.trace_section
            :if={@attempt["error_body"] || @attempt["response_body"] || @attempt["response_headers"]}
            icon="hero-arrow-down-tray"
            label={"Received from #{@attempt["provider"]}"}
          >
            <%!-- error_body is `details[:body]`, straight off the wire — the one
                 response artifact on an attempt the provider itself wrote, and
                 the reason this attempt is on the page, so it opens itself. --%>
            <.trace_toggle
              :if={@attempt["error_body"]}
              id={"trace-error-body-#{@hop.index}"}
              open
              tone={:error}
              label="Error response — the provider's own bytes"
              meta={payload_size(@attempt["error_body"])}
            >
              <.json_panel
                id={"trace-error-#{@hop.index}"}
                content={format_json(@attempt["error_body"])}
              />
            </.trace_toggle>

            <%!-- `response_body` is what the *adapter* returned: Anthropic runs
                 convert_to_openai_format/1 before this is ever stored. Calling it
                 "Response Body" under a provider node reads as that provider's
                 bytes, which we do not keep for a successful response. --%>
            <.trace_toggle
              :if={@attempt["response_body"]}
              id={"trace-response-body-#{@hop.index}"}
              label="Body — converted to the proxy's normalized form"
              meta={payload_size(@attempt["response_body"])}
            >
              <p class="mb-1 text-base-content/40">
                This provider's own response bytes are not stored for a successful attempt.
              </p>
              <.json_panel
                id={"trace-response-#{@hop.index}"}
                content={format_json(@attempt["response_body"])}
              />
            </.trace_toggle>

            <.trace_toggle
              :if={@attempt["response_headers"]}
              id={"trace-response-headers-#{@hop.index}"}
              label="Headers"
              meta={header_count(@attempt["response_headers"])}
            >
              <.trace_headers headers={@attempt["response_headers"]} />
            </.trace_toggle>
          </.trace_section>
        </div>
      </div>
    </div>
    """
  end

  attr :log, :map, required: true
  attr :format, :string, default: nil
  attr :resp_headers, :list, default: nil

  defp trace_client_response(assigns) do
    ~H"""
    <div id="trace-node-client-response" class="relative pl-7">
      <span class="absolute left-0 top-1 size-[18px] rounded-full border-2 border-primary bg-base-100">
      </span>
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-sm font-semibold">You received</span>
        <span
          :if={@format}
          class="badge badge-sm badge-ghost font-mono"
          title="Inferred from the headers you sent — your request body is not stored"
        >
          {@format} format
        </span>
        <span :if={@log.http_status} class="text-xs font-mono text-base-content/50">
          {@log.http_status}
        </span>
      </div>
      <%!-- The row stores the IR, not the bytes the egress wrote. For an
           OpenAI-format client those are the same thing; for anyone else they
           are not, and saying "returned to you" over a converted body is the
           same lie as calling the outbound request the client's own. --%>
      <div class="mt-1.5">
        <.trace_toggle
          :if={@log.response_body}
          id="trace-client-response-body"
          label={
            if @format in [nil, "openai"],
              do: "Response body returned to you",
              else: "Response body, recorded before conversion to #{@format}"
          }
          meta={payload_size(@log.response_body)}
        >
          <.json_panel
            id="trace-client-response"
            content={format_json(@log.response_body)}
            copy_id="copy-response-json"
            max_height="max-h-[calc(100vh-320px)]"
          />
        </.trace_toggle>
        <.trace_toggle
          :if={@resp_headers}
          id="trace-client-response-headers"
          label="Headers returned to you"
          meta={header_count(@resp_headers)}
        >
          <.trace_headers headers={@resp_headers} />
        </.trace_toggle>
      </div>
    </div>
    """
  end

  # One disclosure idiom for every artifact in the trace. Rendered as uppercase
  # primary links, a header list and a response body carried identical weight and
  # an attempt node read as four shouted sentences; the house idiom elsewhere in
  # the app is a chevron, a sentence-case label, and its size in the margin.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :meta, :string, default: nil
  attr :open, :boolean, default: false
  attr :tone, :atom, default: :neutral
  slot :inner_block, required: true

  defp trace_toggle(assigns) do
    ~H"""
    <details id={@id} open={@open} class="group">
      <summary class={[
        "cursor-pointer select-none list-none -mx-2 flex items-center gap-2 rounded-md px-2 py-1.5",
        "text-xs transition-colors hover:bg-base-200/60",
        @tone == :error && "text-error/90 hover:text-error",
        @tone == :neutral && "text-base-content/60 hover:text-base-content"
      ]}>
        <.icon
          name="hero-chevron-right"
          class="size-3 shrink-0 transition-transform group-open:rotate-90"
        />
        <span class="font-medium">{@label}</span>
        <span :if={@meta} class="ml-auto shrink-0 font-mono text-[10px] text-base-content/40">
          {@meta}
        </span>
      </summary>
      <div class="mt-1 mb-2 pl-5">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  # Groups an attempt's artifacts by the direction they travelled, so the node
  # reads as a hop rather than as a list of payloads with no sides.
  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp trace_section(assigns) do
    ~H"""
    <div class="mt-2.5 border-t border-base-300/50 pt-2">
      <div class="flex items-center gap-1.5 text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
        <.icon name={@icon} class="size-3 shrink-0" />
        {@label}
      </div>
      <div class="mt-0.5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :headers, :list, required: true

  defp trace_headers(assigns) do
    ~H"""
    <div class="rounded bg-base-200 p-2 font-mono text-[11px] space-y-1">
      <div :for={{key, value} <- header_pairs(@headers)} class="flex gap-2">
        <span class="text-base-content/50 shrink-0">{key}:</span>
        <span class="break-all">{value}</span>
      </div>
    </div>
    """
  end

  # Stored headers are JSON pairs; the client's own arrive already zipped.
  defp header_pairs(headers) do
    Enum.map(headers, fn
      [key, value] -> {key, value}
      {key, value} -> {key, value}
      other -> {other, ""}
    end)
  end

  # Spelled out: a bare number in the margin of a row already labelled "Headers"
  # sits in the same column as "12.4 KB" and reads as a size.
  defp header_count([_one]), do: "1 header"
  defp header_count(headers) when is_list(headers), do: "#{length(headers)} headers"
  defp header_count(_), do: nil

  defp payload_size(body) when is_binary(body), do: format_bytes(byte_size(body))
  defp payload_size(_), do: nil

  defp change_count([_one]), do: "1 thing"
  defp change_count(changes), do: "#{length(changes)} things"

  defp attempt_error_message(attempt) do
    case attempt["error_body"] do
      body when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"message" => msg}}} -> msg
          {:ok, %{"error" => msg}} when is_binary(msg) -> msg
          _ -> String.slice(body, 0, 120)
        end

      _ ->
        nil
    end
  end

  defp parse_headers(nil), do: nil

  defp parse_headers(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, headers} when is_list(headers) ->
        Enum.map(headers, fn
          [k, v] -> {k, v}
          {k, v} -> {k, v}
          other -> other
        end)

      _ ->
        nil
    end
  end

  defp format_json(nil), do: ""

  defp format_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> Map.delete("_truncation_flags")
        |> deep_parse_json_strings()
        |> Jason.encode!(pretty: true)

      {:ok, decoded} ->
        Jason.encode!(deep_parse_json_strings(decoded), pretty: true)

      _ ->
        str
    end
  end

  defp deep_parse_json_strings(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_parse_json_strings(v)} end)
  end

  defp deep_parse_json_strings(list) when is_list(list) do
    Enum.map(list, &deep_parse_json_strings/1)
  end

  defp deep_parse_json_strings(str) when is_binary(str) do
    if String.length(str) > 2 and String.starts_with?(str, ["{", "["]) do
      case Jason.decode(str) do
        {:ok, decoded} -> deep_parse_json_strings(decoded)
        _ -> str
      end
    else
      str
    end
  end

  defp deep_parse_json_strings(other), do: other

  # Reasoning effort snapshotted into the attempt at request time.
  # Old logs (before the snapshot included it) return nil.
  defp attempt_effort(%{"reasoning_effort" => effort}) when is_binary(effort) and effort != "",
    do: effort

  defp attempt_effort(_), do: nil

  defp provider_time(%{attempted_steps: steps}) when is_list(steps) do
    steps
    |> Enum.map(fn step -> step["latency_ms"] || 0 end)
    |> Enum.sum()
  end

  defp provider_time(_), do: 0

  defp overhead_time(%{latency_ms: total} = log) when is_integer(total) do
    total - provider_time(log)
  end

  defp overhead_time(_), do: 0

  # "11526ms" reads worse than "11.5s"; nil renders as an em dash, not "-ms"
  defp fmt_ms(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp fmt_ms(ms) when is_integer(ms), do: "#{ms}ms"
  defp fmt_ms(_), do: "—"

  defp wait_time(%{ttfb_ms: ttfb, upload_ms: upload})
       when is_integer(ttfb) and is_integer(upload) do
    ttfb - upload
  end

  defp wait_time(_), do: "-"

  # Router-median comparison basis for the request's Total latency (see the
  # comment above the "Overhead" row) — omitted when the router has no other
  # recent traffic to compare against (sample_size <= 1 means this log is
  # its own only data point).
  defp total_baseline_note(log, baselines) do
    with true <- is_integer(log.latency_ms),
         true <- (baselines[:sample_size] || 0) > 1,
         p50 when is_number(p50) <- baselines[:p50_latency_ms] do
      "router median #{fmt_ms(round(p50))} · 24h"
    else
      _ -> nil
    end
  end

  defp cost_baseline_note(log, baselines) do
    with true <- match?(%Decimal{}, log.estimated_cost_usd),
         true <- (baselines[:sample_size] || 0) > 1,
         median when is_number(median) <- decimal_to_float(baselines[:median_cost_usd]) do
      "router median $#{:erlang.float_to_binary(median, decimals: 4)} · 24h"
    else
      _ -> nil
    end
  end

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(v) when is_float(v), do: v
  defp decimal_to_float(_), do: nil

  # Marks the hop that dominates this request's own routing chain (>60% of
  # the summed attempt latencies) — a within-request comparison against the
  # OTHER hops of the same request, not a router-wide baseline, so it needs
  # no query. Only meaningful with 2+ attempts; a single-attempt chain has
  # nothing to compare against.
  defp dominant_hop_flags(steps) when is_list(steps) and length(steps) >= 2 do
    total = steps |> Enum.map(&(&1["latency_ms"] || 0)) |> Enum.sum()
    max_latency = steps |> Enum.map(&(&1["latency_ms"] || 0)) |> Enum.max(fn -> 0 end)
    threshold = total * 0.6

    {marked, _} =
      Enum.map_reduce(steps, false, fn step, marked_already ->
        latency = step["latency_ms"] || 0

        dominant? =
          not marked_already and total > 0 and latency == max_latency and latency > threshold

        {{step, dominant?}, marked_already or dominant?}
      end)

    marked
  end

  defp dominant_hop_flags(steps) when is_list(steps), do: Enum.map(steps, &{&1, false})
  defp dominant_hop_flags(_), do: []

  # Non-overlapping partition of `latency_ms` for the timing share bar — see
  # the comment above the <Charts.share_bar> call for why this split (and not
  # a bar built straight from Total/Provider/TTFB/Upload/Wait/Proc) is the one
  # that's actually safe to plot: those fields overlap each other, this
  # doesn't.
  #
  # `overhead = total - provider_time` is exact by construction (that's what
  # `overhead_time/1` already computes). The remaining budget — `available`
  # below — is handed out to Upload, Wait and Provider-processing *in that
  # order, clamped to what's left*, rather than by clamping each to itself
  # and letting "Unattributed" mop up: on an old row where `attempted_steps`
  # is missing (so `provider_time` under-counts) but `ttfb_ms`/`upload_ms`
  # are present, upload+wait+proc can exceed `provider_time`, and naively
  # summing all five segments would then overshoot Total. Clamping
  # sequentially guarantees the five segments always sum to exactly
  # `latency_ms`, so the bar's proportions are never a lie — a row missing
  # the finer fields just renders honestly with more of the time folded into
  # "Unattributed" (or, if attempted_steps is missing too, into "Overhead").
  defp timing_segments(log) do
    total = log.latency_ms || 0
    overhead = max(overhead_time(log), 0)
    available = max(total - overhead, 0)

    upload = min(log.upload_ms || 0, available)
    remaining = available - upload

    wait =
      case log do
        %{ttfb_ms: ttfb} when is_integer(ttfb) ->
          min(max(ttfb - (log.upload_ms || 0), 0), remaining)

        _ ->
          0
      end

    remaining = remaining - wait
    proc = min(log.provider_processing_ms || 0, remaining)
    unattributed = remaining - proc

    [
      %{
        key: "upload",
        name: "Upload",
        value: upload,
        display: fmt_ms(upload),
        color: Charts.series_color(0)
      },
      %{
        key: "wait",
        name: "Wait",
        value: wait,
        display: fmt_ms(wait),
        color: Charts.series_color(1)
      },
      %{
        key: "processing",
        name: "Provider processing",
        value: proc,
        display: fmt_ms(proc),
        color: Charts.series_color(2)
      },
      %{
        key: "unattributed",
        name: "Unattributed",
        value: unattributed,
        display: fmt_ms(unattributed),
        color: Charts.series_color(3)
      },
      %{
        key: "overhead",
        name: "Proxy overhead",
        value: overhead,
        display: fmt_ms(overhead),
        color: Charts.series_color(4)
      }
    ]
  end

  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"

  defp cache_pct(log) do
    case Usage.cache_hit_pct(log.prompt_tokens, log.cache_read_tokens, log.cache_write_tokens, 0) do
      nil -> ""
      pct -> "#{trunc(pct)}%"
    end
  end

  @attribution_labels [
    {"system", "System prompt"},
    {"tools", "Tool definitions"},
    {"history", "History"},
    {"tool_results", "Tool results"},
    {"file_contents", "File contents"}
  ]

  # Non-empty buckets, largest first, with shares of the billed total.
  defp attribution_rows(%{token_attribution: %{"buckets" => buckets, "basis_tokens" => basis}})
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

  defp attribution_rows(_log), do: []

  defp new_input(%{prompt_tokens: nil}), do: "—"

  defp new_input(log),
    do: Usage.new_input_tokens(log.prompt_tokens, log.cache_read_tokens, log.cache_write_tokens)
end
