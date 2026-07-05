defmodule DodoRouterWeb.LogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
  alias DodoRouter.Logs.Provenance
  alias DodoRouter.Proxy.Adapter.Registry
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

    req_headers = req_headers

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
      |> assign(:show_req_headers, false)
      |> assign(:show_resp_headers, false)
      |> assign(:expanded_messages, MapSet.new())
      |> assign(:truncation_flags, log.truncation_flags || [])
      |> assign(:replay_count, Logs.replay_counts([log.id]) |> Map.get(log.id, 0))

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

  def handle_event("toggle_req_headers", _params, socket) do
    {:noreply, update(socket, :show_req_headers, &(!&1))}
  end

  def handle_event("toggle_resp_headers", _params, socket) do
    {:noreply, update(socket, :show_resp_headers, &(!&1))}
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
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div class="flex-1">
          <h1 class="text-2xl font-bold">Request Details</h1>
          <code class="text-sm text-base-content/60">{@log.request_id}</code>
        </div>
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
      <div class="flex-1 flex overflow-hidden">
        <!-- Left sidebar -->
        <div class="w-52 border-r border-base-300/30 overflow-y-auto p-3 space-y-4 bg-base-100/30">
          <!-- Status -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Status
            </div>
            <div class="text-lg"><.status_badge status={@log.status} /></div>
          </div>
          
    <!-- Timing -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Timing
            </div>
            <div class="space-y-1 text-xs">
              <div class="flex justify-between">
                <span class="text-base-content/60">Total</span>
                <span class="font-mono">{@log.latency_ms || "-"}ms</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Provider</span>
                <span class="font-mono">{provider_time(@log)}ms</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Overhead</span>
                <span class="font-mono">{overhead_time(@log)}ms</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">TTFB</span>
                <span class="font-mono">{@log.ttfb_ms || "-"}ms</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Upload</span>
                <span class="font-mono">{@log.upload_ms || "-"}ms</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Wait</span>
                <span class="font-mono">{wait_time(@log)}ms</span>
              </div>
              <%= if @log.provider_processing_ms do %>
                <div class="flex justify-between">
                  <span class="text-base-content/60">Proc</span>
                  <span class="font-mono">{@log.provider_processing_ms}ms</span>
                </div>
              <% end %>
            </div>
          </div>
          
    <!-- Model -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Model
            </div>
            <div class="text-sm font-mono">{@log.final_model}</div>
            <div class="flex items-center gap-1.5 mt-1">
              <div class="w-3.5 h-3.5 rounded flex items-center justify-center shrink-0 bg-base-200">
                <.provider_logo slug={normalize_slug(@log.final_provider)} class="w-2.5 h-2.5" />
              </div>
              <div class="text-xs text-base-content/60">{@log.final_provider}</div>
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
          
    <!-- Usage -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Usage
            </div>
            <div class="space-y-1 text-xs">
              <div class="flex justify-between">
                <span class="text-base-content/60">Type</span>
                <span class="text-right"><.call_type_badge type={@log.call_type} /></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Tokens</span>
                <span class="font-mono">{@log.total_tokens || "-"}</span>
              </div>
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
              <div class="flex justify-between">
                <span class="text-base-content/60">Cost</span>
                <span class="font-mono">
                  {if @log.estimated_cost_usd,
                    do: "$#{Decimal.round(@log.estimated_cost_usd, 4)}",
                    else: "-"}
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Size</span>
                <span class="font-mono">{format_bytes(@log.payload_size_bytes)}</span>
              </div>
            </div>
          </div>

          <%= if length(@log.tools_invoked) > 0 do %>
            <div>
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
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Routing
            </div>
            <div class="space-y-1">
              <%= for {attempt, _idx} <- Enum.with_index(@log.attempted_steps) do %>
                <div class="flex items-center gap-1.5 text-xs">
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
                  <span class="text-base-content/40 font-mono ml-auto">
                    {attempt["latency_ms"]}ms
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Right content -->
        <div class="flex-1 overflow-hidden flex flex-col">
          <!-- Tabs -->
          <div class="border-b border-base-300/30 px-4 pt-2">
            <div class="flex gap-1" role="tablist">
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
                phx-value-tab="raw_request"
                role="tab"
                aria-selected={@active_tab == "raw_request"}
                class={[
                  "px-3 py-1.5 text-xs font-medium rounded-t-lg transition",
                  @active_tab == "raw_request" &&
                    "bg-base-100 text-base-content border-t border-x border-base-300/30 -mb-px",
                  @active_tab != "raw_request" &&
                    "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
                ]}
              >
                Original Request
              </button>
              <button
                type="button"
                phx-click="set_tab"
                phx-value-tab="raw_response"
                role="tab"
                aria-selected={@active_tab == "raw_response"}
                class={[
                  "px-3 py-1.5 text-xs font-medium rounded-t-lg transition",
                  @active_tab == "raw_response" &&
                    "bg-base-100 text-base-content border-t border-x border-base-300/30 -mb-px",
                  @active_tab != "raw_response" &&
                    "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
                ]}
              >
                Final Response
              </button>
              <button
                type="button"
                phx-click="set_tab"
                phx-value-tab="fallback_trace"
                role="tab"
                aria-selected={@active_tab == "fallback_trace"}
                class={[
                  "px-3 py-1.5 text-xs font-medium rounded-t-lg transition",
                  @active_tab == "fallback_trace" &&
                    "bg-base-100 text-base-content border-t border-x border-base-300/30 -mb-px",
                  @active_tab != "fallback_trace" &&
                    "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
                ]}
              >
                {if length(@log.attempted_steps) > 1, do: "Fallback Trace", else: "Provider Details"}
              </button>
            </div>
          </div>
          
    <!-- Tab panels -->
          <div class="flex-1 overflow-y-auto">
            <%= if @active_tab == "conversation" do %>
              <div class="p-4">
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
                  replay_base={if(@log.replayed_from_id, do: nil, else: ~p"/logs/#{@log.id}/replay")}
                />
              </div>
            <% end %>

            <%= if @active_tab == "raw_request" do %>
              <div class="p-4 space-y-3">
                <% final_attempt = List.last(@log.attempted_steps) %>
                <%= if final_attempt do %>
                  <div class="space-y-2">
                    <%= if final_attempt["endpoint"] do %>
                      <div class="flex items-center gap-2">
                        <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
                          Endpoint
                        </span>
                        <span class="font-mono text-base-content/70 text-xs break-all">
                          {final_attempt["endpoint"]}
                        </span>
                      </div>
                    <% end %>
                    <%= if final_attempt["provider_key_id"] && final_attempt["provider_key_slug"] do %>
                      <div class="flex items-center gap-2">
                        <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
                          API Key
                        </span>
                        <.link
                          navigate={
                            ~p"/providers?highlight=#{final_attempt["provider_key_id"]}&provider=#{final_attempt["provider_key_slug"]}"
                          }
                          class="text-xs text-primary hover:underline"
                        >
                          {final_attempt["provider_key_label"] || "Key"}
                        </.link>
                      </div>
                    <% end %>
                    <%= if final_attempt["outbound_headers"] do %>
                      <div>
                        <button
                          type="button"
                          phx-click={JS.toggle(to: "#original-outbound-headers")}
                          class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold"
                        >
                          Outbound Headers
                        </button>
                        <div id="original-outbound-headers" class="hidden">
                          <div class="mt-2 p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                            <%= for [key, value] <- final_attempt["outbound_headers"] do %>
                              <div class="flex gap-2">
                                <span class="text-base-content/60 shrink-0">{key}:</span>
                                <span class="break-all">{value}</span>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    <% end %>
                    <%= if final_attempt["outbound_body"] do %>
                      <div>
                        <button
                          type="button"
                          phx-click={JS.toggle(to: "#original-outbound-body")}
                          class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold"
                        >
                          Outbound Request (sent to provider)
                        </button>
                        <div id="original-outbound-body" class="hidden">
                          <div class="mt-2 mockup-code text-xs max-h-64 overflow-auto">
                            <pre><code><%= format_json(final_attempt["outbound_body"]) %></code></pre>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <%= if @req_headers do %>
                  <div>
                    <button
                      type="button"
                      phx-click="toggle_req_headers"
                      class="text-xs text-primary hover:underline"
                    >
                      {if @show_req_headers, do: "Hide headers", else: "Show headers"}
                    </button>
                    <%= if @show_req_headers do %>
                      <div class="mt-2 p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                        <%= for {key, value} <- @req_headers do %>
                          <div class="flex gap-2">
                            <span class="text-base-content/60 shrink-0">{key}:</span>
                            <span class="break-all">{value}</span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <div class="mockup-code text-xs max-h-[calc(100vh-240px)] overflow-auto">
                  <pre><code><%= format_json(@log.request_body) %></code></pre>
                </div>
              </div>
            <% end %>

            <%= if @active_tab == "raw_response" do %>
              <div class="p-4 space-y-3">
                <%= if @resp_headers do %>
                  <div>
                    <button
                      type="button"
                      phx-click="toggle_resp_headers"
                      class="text-xs text-primary hover:underline"
                    >
                      {if @show_resp_headers, do: "Hide headers", else: "Show headers"}
                    </button>
                    <%= if @show_resp_headers do %>
                      <div class="mt-2 p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                        <%= for {key, value} <- @resp_headers do %>
                          <div class="flex gap-2">
                            <span class="text-base-content/60 shrink-0">{key}:</span>
                            <span class="break-all">{value}</span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <div class="mockup-code text-xs max-h-[calc(100vh-240px)] overflow-auto">
                  <pre><code><%= format_json(@log.response_body) %></code></pre>
                </div>
              </div>
            <% end %>

            <%= if @active_tab == "fallback_trace" do %>
              <div class="p-4 space-y-3">
                <div class="text-sm text-base-content/60 mb-2">
                  Request was retried across {length(@log.attempted_steps)} providers before succeeding.
                </div>
                <%= for {attempt, idx} <- Enum.with_index(@log.attempted_steps) do %>
                  <div class={[
                    "border rounded-lg overflow-hidden",
                    attempt["status"] == "success" && "border-success/30",
                    attempt["status"] != "success" && "border-error/30"
                  ]}>
                    <div class={[
                      "px-3 py-2 flex items-center justify-between text-xs",
                      attempt["status"] == "success" && "bg-success/5",
                      attempt["status"] != "success" && "bg-error/5"
                    ]}>
                      <div class="flex items-center gap-2">
                        <span class="font-mono text-base-content/40">#{idx + 1}</span>
                        <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
                          <.provider_logo
                            slug={
                              normalize_slug(
                                Registry.to_key_slug(
                                  attempt["provider"],
                                  attempt["plan_type"] || "standard"
                                )
                              )
                            }
                            class="w-3 h-3"
                          />
                        </div>
                        <span class="font-medium">{attempt["provider"]} / {attempt["model"]}</span>
                        <%= if attempt["plan_type"] do %>
                          <span class="badge badge-sm">{attempt["plan_type"]}</span>
                        <% end %>
                        <%= if effort = attempt_effort(attempt) do %>
                          <span
                            class="badge badge-sm badge-accent badge-outline"
                            title="Reasoning effort"
                          >
                            effort: {effort}
                          </span>
                        <% end %>
                        <%= if attempt["status"] == "success" do %>
                          <span class="text-success font-medium">Success</span>
                        <% else %>
                          <span class="text-error font-medium">{attempt["error"]}</span>
                        <% end %>
                      </div>
                      <span class="font-mono text-base-content/60">{attempt["latency_ms"]}ms</span>
                    </div>

                    <div class="px-3 py-2 space-y-2 text-xs">
                      <%= if attempt["endpoint"] do %>
                        <div class="flex items-center gap-2">
                          <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
                            Endpoint
                          </span>
                          <span class="font-mono text-base-content/70 break-all">
                            {attempt["endpoint"]}
                          </span>
                        </div>
                      <% end %>

                      <%= if attempt["provider_key_id"] && attempt["provider_key_slug"] do %>
                        <div class="flex items-center gap-2">
                          <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
                            API Key
                          </span>
                          <.link
                            navigate={
                              ~p"/providers?highlight=#{attempt["provider_key_id"]}&provider=#{attempt["provider_key_slug"]}"
                            }
                            class="font-mono text-primary hover:underline"
                          >
                            {attempt["provider_key_label"]}
                          </.link>
                        </div>
                      <% end %>

                      <%= if attempt["outbound_headers"] do %>
                        <div>
                          <button
                            type="button"
                            phx-click={JS.toggle(to: "#step-outbound-headers-#{idx}")}
                            class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold mb-1"
                          >
                            Outbound Headers
                          </button>
                          <div id={"step-outbound-headers-#{idx}"} class="hidden">
                            <div class="p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                              <%= for [key, value] <- attempt["outbound_headers"] do %>
                                <div class="flex gap-2">
                                  <span class="text-base-content/60 shrink-0">{key}:</span>
                                  <span class="break-all">{value}</span>
                                </div>
                              <% end %>
                            </div>
                          </div>
                        </div>
                      <% end %>

                      <%= if attempt["error_body"] do %>
                        <div>
                          <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
                            Error Response
                          </div>
                          <div class="mockup-code text-xs">
                            <pre><code><%= format_json(attempt["error_body"]) %></code></pre>
                          </div>
                        </div>
                      <% end %>

                      <%= if attempt["request_body"] do %>
                        <div>
                          <button
                            type="button"
                            phx-click={JS.toggle(to: "#step-request-#{idx}")}
                            class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold mb-1"
                          >
                            {if idx == 0, do: "Original Request", else: "Request Sent (transformed)"}
                          </button>
                          <div id={"step-request-#{idx}"} class="hidden">
                            <div class="mockup-code text-xs max-h-64 overflow-auto">
                              <pre><code><%= format_json(attempt["request_body"]) %></code></pre>
                            </div>
                          </div>
                        </div>
                      <% end %>

                      <%= if attempt["outbound_body"] do %>
                        <div>
                          <button
                            type="button"
                            phx-click={JS.toggle(to: "#step-outbound-body-#{idx}")}
                            class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold mb-1"
                          >
                            Outbound Request (sent to provider)
                          </button>
                          <div id={"step-outbound-body-#{idx}"} class="hidden">
                            <div class="mockup-code text-xs max-h-64 overflow-auto">
                              <pre><code><%= format_json(attempt["outbound_body"]) %></code></pre>
                            </div>
                          </div>
                        </div>
                      <% end %>

                      <%= if attempt["response_body"] do %>
                        <div>
                          <button
                            type="button"
                            phx-click={JS.toggle(to: "#step-response-#{idx}")}
                            class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold mb-1"
                          >
                            Response Body
                          </button>
                          <div id={"step-response-#{idx}"} class="hidden">
                            <div class="mockup-code text-xs max-h-64 overflow-auto">
                              <pre><code><%= format_json(attempt["response_body"]) %></code></pre>
                            </div>
                          </div>
                        </div>
                      <% end %>

                      <%= if attempt["response_headers"] do %>
                        <div>
                          <button
                            type="button"
                            phx-click={JS.toggle(to: "#step-headers-#{idx}")}
                            class="text-[10px] uppercase tracking-wider text-primary hover:underline font-semibold mb-1"
                          >
                            Response Headers
                          </button>
                          <div id={"step-headers-#{idx}"} class="hidden">
                            <div class="p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                              <%= for [key, value] <- attempt["response_headers"] do %>
                                <div class="flex gap-2">
                                  <span class="text-base-content/60 shrink-0">{key}:</span>
                                  <span class="break-all">{value}</span>
                                </div>
                              <% end %>
                            </div>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
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
          <div class="mockup-code text-xs max-h-96 overflow-auto">
            <pre><code phx-no-curly-interpolation><%= Jason.encode!(@selected_tool.parameters, pretty: true) %></code></pre>
          </div>
        <% end %>
      </.modal>
    </div>
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
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool Call", "badge-secondary"}
        "tool_enabled_completion" -> {"Tool Enabled", "badge-primary"}
        _ -> {"Completion", "badge-ghost"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={"badge #{@class}"}>{@label}</span>
    """
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
      {:ok, decoded} -> Jason.encode!(deep_parse_json_strings(decoded), pretty: true)
      _ -> str
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

  defp wait_time(%{ttfb_ms: ttfb, upload_ms: upload})
       when is_integer(ttfb) and is_integer(upload) do
    ttfb - upload
  end

  defp wait_time(_), do: "-"

  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"

  defp cache_pct(%{cache_read_tokens: nil}), do: ""

  defp cache_pct(%{cache_read_tokens: cached, prompt_tokens: prompt})
       when is_integer(cached) and is_integer(prompt) and prompt > 0 do
    pct = Float.round(cached / prompt * 100, 0)
    "#{trunc(pct)}%"
  end

  defp cache_pct(_), do: ""
end
