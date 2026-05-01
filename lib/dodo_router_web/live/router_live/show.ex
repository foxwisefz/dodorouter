defmodule DodoRouterWeb.RouterLive.Show do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.Routers
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.Logs
  alias DodoRouter.Providers
  alias DodoRouter.Proxy.Adapter.Registry

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, id) |> Routers.with_routing_steps()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
      Logs.subscribe_to_logs(router.id)
    end

    provider_keys = Providers.list_provider_keys(socket.assigns.current_user)
    recent_logs = Logs.list_logs(router, limit: 10)

    socket =
      socket
      |> assign(:router, router)
      |> assign(:stats, Logs.stats(router))
      |> assign(:recent_events, [])
      |> assign(:stats_timer, nil)
      |> assign(:active_requests, 0)
      |> assign(:active_request, false)
      |> assign(:has_routing_steps, length(router.routing_steps) > 0)
      |> assign(:has_logs, length(recent_logs) > 0)
      |> assign(:snippet_tab, "curl")
      |> assign(:provider_keys, provider_keys)
      |> stream(:routing_steps, router.routing_steps)
      |> stream(:recent_logs, recent_logs)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    assign(socket, :page_title, socket.assigns.router.name)
  end

  defp apply_action(socket, :edit, _params) do
    assign(socket, :page_title, "Edit #{socket.assigns.router.name}")
  end

  defp apply_action(socket, :routing, _params) do
    socket
    |> assign(:page_title, "Routing - #{socket.assigns.router.name}")
    |> assign(:new_step, %RoutingStep{})
    |> assign(:step_provider, "zai")
  end

  @impl true
  def handle_event("set_snippet_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :snippet_tab, tab)}
  end

  def handle_event("update_step_form", %{"step" => %{"provider" => provider}}, socket) do
    {:noreply, assign(socket, :step_provider, provider)}
  end

  def handle_event("update_step_form", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_step", %{"step" => step_params}, socket) do
    # Filter out empty string values
    step_params =
      step_params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    case Routers.create_routing_step(socket.assigns.router, step_params) do
      {:ok, step} ->
        {:noreply,
         socket
         |> stream_insert(:routing_steps, step)
         |> assign(:has_routing_steps, true)
         |> put_flash(:info, "Step added")
         |> push_patch(to: ~p"/routers/#{socket.assigns.router}")}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        Logger.error("Failed to add routing step: #{inspect(errors)}")
        {:noreply, put_flash(socket, :error, "Failed to add step: #{inspect(errors)}")}
    end
  end

  def handle_event("delete_step", %{"id" => id}, socket) do
    step = Routers.get_routing_step!(socket.assigns.router, id)
    {:ok, _} = Routers.delete_routing_step(step)

    remaining = Routers.list_routing_steps(socket.assigns.router)

    {:noreply,
     socket
     |> stream_delete(:routing_steps, step)
     |> assign(:has_routing_steps, length(remaining) > 0)}
  end

  def handle_event("move_step_up", %{"id" => id}, socket) do
    steps = Routers.list_routing_steps(socket.assigns.router)
    step_idx = Enum.find_index(steps, &(&1.id == id))

    if step_idx && step_idx > 0 do
      new_order =
        steps
        |> Enum.map(& &1.id)
        |> swap_at(step_idx, step_idx - 1)

      Routers.reorder_routing_steps(socket.assigns.router, new_order)
      updated_steps = Routers.list_routing_steps(socket.assigns.router)

      {:noreply, stream(socket, :routing_steps, updated_steps, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_step_down", %{"id" => id}, socket) do
    steps = Routers.list_routing_steps(socket.assigns.router)
    step_idx = Enum.find_index(steps, &(&1.id == id))

    if step_idx && step_idx < length(steps) - 1 do
      new_order =
        steps
        |> Enum.map(& &1.id)
        |> swap_at(step_idx, step_idx + 1)

      Routers.reorder_routing_steps(socket.assigns.router, new_order)
      updated_steps = Routers.list_routing_steps(socket.assigns.router)

      {:noreply, stream(socket, :routing_steps, updated_steps, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("assign_key", %{"key_id" => key_id, "step_id" => step_id}, socket) do
    step = Routers.get_routing_step!(socket.assigns.router, step_id)
    provider_key_id = if key_id == "", do: nil, else: key_id

    case Routers.update_routing_step(step, %{provider_key_id: provider_key_id}) do
      {:ok, _updated_step} ->
        updated_steps = Routers.list_routing_steps(socket.assigns.router)
        {:noreply, stream(socket, :routing_steps, updated_steps, reset: true)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to assign API key")}
    end
  end

  def handle_event("regenerate_api_key", _params, socket) do
    case Routers.regenerate_api_key(socket.assigns.router) do
      {:ok, router, api_key} ->
        {:noreply,
         socket
         |> assign(:router, router)
         |> assign(:new_api_key, api_key)
         |> put_flash(:info, "API key regenerated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate API key")}
    end
  end

  @impl true
  def handle_info({:step_started, step_info}, socket) do
    socket =
      if step_info.step_index == 0 do
        active_requests = socket.assigns.active_requests + 1

        socket
        |> assign(:active_requests, active_requests)
        |> assign(:active_request, true)
      else
        socket
      end

    {:noreply,
     push_event(socket, "step_started", %{
       request_id: step_info.request_id,
       step_id: step_info.step_id,
       step_index: step_info.step_index,
       provider: step_info.provider,
       model: step_info.model
     })}
  end

  def handle_info({:step_completed, step_info}, socket) do
    {:noreply,
     push_event(socket, "step_completed", %{
       step_id: step_info.step_id,
       status: to_string(step_info.status),
       latency_ms: step_info.latency_ms
     })}
  end

  def handle_info({:proxy_event, event}, socket) do
    recent_events = [event | Enum.take(socket.assigns.recent_events, 9)]

    if socket.assigns[:stats_timer], do: Process.cancel_timer(socket.assigns[:stats_timer])
    timer = Process.send_after(self(), :refresh_stats, 500)

    active_requests = max(0, socket.assigns.active_requests - 1)

    {:noreply,
     socket
     |> assign(:recent_events, recent_events)
     |> assign(:stats_timer, timer)
     |> assign(:active_requests, active_requests)
     |> assign(:active_request, active_requests > 0)
     |> push_event("request_completed", %{
       request_id: event.request_id,
       status: to_string(event.status)
     })}
  end

  def handle_info(:refresh_stats, socket) do
    stats = Logs.stats(socket.assigns.router)
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_info({:log_pending, pending}, socket) do
    # Use request_id as stream key so completed log replaces it in place
    pending = Map.put(pending, :id, pending.request_id)

    {:noreply,
     socket
     |> assign(:has_logs, true)
     |> stream_insert(:recent_logs, pending, at: 0, limit: 10)}
  end

  def handle_info({:log_created, log}, socket) do
    # Use request_id as key to replace pending entry in place
    log = Map.put(log, :id, log.request_id)

    {:noreply,
     socket
     |> assign(:has_logs, true)
     |> stream_insert(:recent_logs, log)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="router-show-page" class="relative overflow-hidden" phx-hook="PulseRing">
      <!-- Content -->
      <div class="relative z-10">
        <!-- Header -->
        <div
          id="router-header"
          class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8"
        >
          <div>
            <div class="flex items-center gap-3">
              <.link
                navigate={~p"/routers"}
                class="p-2 rounded-lg hover:bg-base-200 transition-colors text-base-content/60 hover:text-base-content"
              >
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
              <div>
                <h1 class="text-2xl font-bold">{@router.name}</h1>
                <p class="text-base-content/50 font-mono text-sm">{@router.slug}</p>
              </div>
            </div>
          </div>
          <.link
            patch={~p"/routers/#{@router}/routing"}
            class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
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
                d="M4 6h16M4 12h16M4 18h7"
              />
            </svg>
            Routing
          </.link>
        </div>
        
    <!-- New API Key Alert -->
        <div :if={assigns[:new_api_key]} class="card-bordered p-4 mb-6 border-warning/50 bg-warning/5">
          <div class="flex gap-3">
            <div class="stat-icon bg-warning/10 text-warning flex-shrink-0">
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
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
            </div>
            <div class="flex-1">
              <h3 class="font-semibold text-warning">New API key generated!</h3>
              <p class="text-sm text-base-content/60">Save it now - this won't be shown again.</p>
              <code class="block mt-2 p-3 bg-base-300 rounded-lg font-mono text-sm break-all select-all">
                {@new_api_key}
              </code>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/routers/#{@router}/recordings"}
            class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
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
                d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12a3 3 0 106 0 3 3 0 00-6 0z"
              />
            </svg>
            Recordings
          </.link>
          <.link
            navigate={~p"/routers/#{@router}/sessions"}
            class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
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
                d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
            Sessions
          </.link>
          <.link
            patch={~p"/routers/#{@router}/routing"}
            class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
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
                d="M4 6h16M4 12h16M4 18h7"
              />
            </svg>
            Routing
          </.link>
        </div>
        
    <!-- Stats -->
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-8">
          <div class="stat-card">
            <div class="stat-label">Requests (24h)</div>
            <div class="stat-value">{@stats.total_requests}</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Success Rate</div>
            <div class={["stat-value", success_color(@stats)]}>{success_rate(@stats)}</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Tokens Used</div>
            <div class="stat-value">{format_number(@stats.total_tokens)}</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Avg Latency</div>
            <div class="stat-value">{format_latency(@stats.avg_latency_ms)}</div>
          </div>
        </div>
        
    <!-- Quick Start -->
        <div class="card-bordered mb-8">
          <div class="flex items-center justify-between mb-3">
            <h2 class="section-title mb-0">Quick Start</h2>
            <div class="flex bg-base-200 rounded-lg p-1 gap-1">
              <button
                phx-click="set_snippet_tab"
                phx-value-tab="curl"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "curl", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                cURL
              </button>
              <button
                phx-click="set_snippet_tab"
                phx-value-tab="python"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "python", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                Python
              </button>
              <button
                phx-click="set_snippet_tab"
                phx-value-tab="node"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "node", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                Node.js
              </button>
            </div>
          </div>

          <div class="code-block">
            <pre class="text-xs text-base-content/80"><code><%= raw(snippet_for_tab(@snippet_tab, base_url(), @router.slug)) %></code></pre>
          </div>

          <p class="text-sm text-base-content/50 mt-3">
            Replace <code class="text-primary font-medium">YOUR_API_KEY</code>
            with your router API key:
            <code class="font-mono text-base-content/70">{@router.api_key_prefix}...</code>
          </p>
        </div>
        
    <!-- Routing Chain -->
        <div class="card-bordered mb-8" id="routing-chain-container" phx-hook="RequestFlowAnimation">
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-3">
              <h2 class="section-title mb-0">Routing Chain</h2>
              <div
                :if={@active_request}
                class="flex items-center gap-2 px-2.5 py-1 bg-green-500/25 rounded-full text-xs font-medium text-green-400"
              >
                <span class="request-flow-pulse w-2 h-2 rounded-full bg-green-400"></span>
                Processing...
              </div>
            </div>
            <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-primary btn-sm">
              Add Step
            </.link>
          </div>
          <div id="routing-steps" phx-update="stream" class="relative">
            <div
              :for={{dom_id, step} <- @streams.routing_steps}
              id={dom_id}
              data-step-id={step.id}
              data-step-index={step.position}
              class="step-card-wrapper"
            >
              <!-- Connecting line between steps -->
              <div
                :if={step.position > 0}
                class="step-connector"
                data-connector-index={step.position}
              >
                <div class="step-connector-line"></div>
                <div class="step-connector-pulse"></div>
              </div>
              <!-- The step card itself -->
              <div class="step-card flex items-center gap-4 relative overflow-hidden">
                <!-- Animated border glow overlay -->
                <div class="step-glow-overlay"></div>
                <!-- Step number with status ring -->
                <div class="step-number-ring" data-step-number={step.position + 1}>
                  <div class="w-8 h-8 rounded-full bg-primary/20 text-primary flex items-center justify-center font-bold text-sm flex-shrink-0 relative z-10">
                    {step.position + 1}
                  </div>
                </div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="font-medium text-base-content/90">{step.provider}</span>
                    <span class="text-base-content/40">/</span>
                    <span class="font-mono text-sm text-base-content/70">{step.model}</span>
                    <span
                      :if={step.plan_type == "coding"}
                      class="px-1.5 py-0.5 rounded text-xs bg-secondary/20 text-secondary"
                    >
                      coding
                    </span>
                    <span
                      :if={step.thinking_enabled}
                      class="px-1.5 py-0.5 rounded text-xs bg-accent/20 text-accent"
                    >
                      thinking
                    </span>
                  </div>
                  <div class="mt-2">
                    <.form for={%{}} phx-change="assign_key">
                      <input type="hidden" name="step_id" value={step.id} />
                      <select
                        name="key_id"
                        class={"text-sm py-1.5 px-3 rounded-lg border transition-colors appearance-none bg-no-repeat bg-right pr-8 #{if step.provider_key_id, do: "bg-base-200/50 border-base-300/30 text-base-content/70", else: "bg-warning/5 border-warning/30 text-warning"}"}
                        style="background-image: url('data:image/svg+xml;charset=UTF-8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 20 20%22 fill=%22%236b7280%22%3E%3Cpath fill-rule=%22evenodd%22 d=%22M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z%22 clip-rule=%22evenodd%22/%3E%3C/svg%3E');"
                      >
                        <option value="">-- Select API Key --</option>
                        <%= for key <- matching_keys(@provider_keys, step) do %>
                          <option value={key.id} selected={step.provider_key_id == key.id}>
                            {key.label} ({key.key_hint})
                          </option>
                        <% end %>
                      </select>
                    </.form>
                  </div>
                </div>
                <div class="flex flex-col gap-1">
                  <button
                    phx-click="move_step_up"
                    phx-value-id={step.id}
                    class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors"
                    title="Move up"
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
                        d="M5 15l7-7 7 7"
                      />
                    </svg>
                  </button>
                  <button
                    phx-click="move_step_down"
                    phx-value-id={step.id}
                    class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors"
                    title="Move down"
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
                        d="M19 9l-7 7-7-7"
                      />
                    </svg>
                  </button>
                </div>
                <button
                  phx-click="delete_step"
                  phx-value-id={step.id}
                  class="p-2 rounded-lg hover:bg-error/10 text-base-content/40 hover:text-error transition-colors"
                  data-confirm="Remove this step?"
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
                      d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                    />
                  </svg>
                </button>
              </div>
            </div>
          </div>
          <p :if={!@has_routing_steps} class="empty-state py-8">
            No routing steps configured. Add one to start proxying requests.
          </p>
        </div>
        
    <!-- Recent Logs -->
        <div class="card-bordered mb-8" id="recent-logs-card">
          <div class="flex items-center justify-between mb-3">
            <h2 class="section-title mb-0">Recent Logs</h2>
            <.link
              navigate={~p"/logs?router_id=#{@router.id}"}
              class="text-sm text-primary hover:underline"
            >
              View all logs
            </.link>
          </div>
          <div id="recent-logs" phx-update="stream" phx-hook="LogEntryAnimations" class="space-y-2">
            <.link
              :for={{dom_id, log} <- @streams.recent_logs}
              id={dom_id}
              navigate={
                if log.status != "pending",
                  do:
                    ~p"/logs/#{log}" <> "?return_to=" <> URI.encode_www_form("/routers/#{@router.id}"),
                  else: nil
              }
              class={[
                "flex items-center justify-between p-3 rounded-lg text-sm transition-colors",
                log.status == "pending" && "bg-info/10 animate-pulse",
                log.status == "success" && "bg-success/10 hover:bg-success/20",
                log.status == "fallback" && "bg-warning/10 hover:bg-warning/20",
                log.status == "error" && "bg-error/10 hover:bg-error/20"
              ]}
            >
              <div class="flex items-center gap-3">
                <span class={[
                  "w-2 h-2 rounded-full",
                  log.status == "pending" && "bg-info",
                  log.status == "success" && "bg-success",
                  log.status == "fallback" && "bg-warning",
                  log.status == "error" && "bg-error"
                ]}>
                </span>
                <span class="font-mono text-base-content/80">
                  {log.final_provider}/{log.final_model}
                </span>
                <span class={"px-1.5 py-0.5 rounded text-xs font-medium #{status_badge_class(log.status)}"}>
                  {log.status}
                </span>
              </div>
              <div class="flex items-center gap-4 text-base-content/50 text-sm">
                <span :if={Map.get(log, :latency_ms)} class="font-mono">{log.latency_ms}ms</span>
                <span class="font-mono text-xs">{format_time(log.inserted_at)}</span>
              </div>
            </.link>
          </div>
          <p :if={!@has_logs} class="empty-state py-8">
            No requests yet. Use the Quick Start snippet above to make your first request.
          </p>
        </div>
        
    <!-- Live Events -->
        <div :if={length(@recent_events) > 0} class="card-bordered">
          <div class="flex items-center gap-3 mb-3">
            <h2 class="section-title mb-0">Recent Events</h2>
            <span class="flex items-center gap-1.5 px-2 py-0.5 bg-success/10 rounded text-xs font-medium text-success">
              <span class="live-dot"></span> Live
            </span>
          </div>
          <div class="space-y-2">
            <div
              :for={event <- @recent_events}
              class={"flex items-center justify-between p-3 rounded-lg text-sm #{event_class(event)}"}
            >
              <div class="flex items-center gap-3">
                <span class={"w-2 h-2 rounded-full #{event_dot_class(event)}"}></span>
                <span class="font-mono text-base-content/80">{event.provider}/{event.model}</span>
                <span
                  :if={event.had_fallback}
                  class="px-1.5 py-0.5 bg-warning/20 text-warning rounded text-xs"
                >
                  fallback
                </span>
              </div>
              <span class="text-base-content/50 font-mono">{event.latency_ms}ms</span>
            </div>
          </div>
        </div>
        
    <!-- Routing Modal -->
        <.modal
          :if={@live_action == :routing}
          id="routing-modal"
          show
          on_cancel={JS.patch(~p"/routers/#{@router}")}
        >
          <h3 class="text-lg font-semibold mb-6">Add Routing Step</h3>
          <form phx-submit="add_step" phx-change="update_step_form" class="space-y-5">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Provider</label>
              <select
                name="step[provider]"
                class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
                required
              >
                <%= for {slug, config} <- Enum.sort_by(Registry.all_adapters(), fn {s, _} -> s end) do %>
                  <option value={slug} selected={@step_provider == slug}>
                    {config.display_name}
                  </option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Model</label>
              <input
                type="text"
                name="step[model]"
                placeholder={
                  case Registry.available_models(@step_provider) do
                    [] -> "e.g. gpt-4"
                    [first | _] -> "e.g. #{first}"
                  end
                }
                class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
                required
              />
            </div>
            <%!-- z.ai specific options --%>
            <div :if={@step_provider == "zai"}>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Plan Type</label>
              <select
                name="step[plan_type]"
                class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
              >
                <option value="standard">Standard (/api/paas/v4)</option>
                <option value="coding">Coding Plan (/api/coding/paas/v4)</option>
              </select>
              <p class="text-xs text-base-content/50 mt-1.5">
                Select based on your z.ai subscription
              </p>
            </div>
            <%!-- Moonshot specific options --%>
            <div :if={@step_provider == "moonshot"}>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Endpoint</label>
              <select
                name="step[plan_type]"
                class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
              >
                <option value="standard">Standard (api.moonshot.ai/v1)</option>
                <option value="coding">Kimi Code (api.kimi.com/coding/v1)</option>
              </select>
              <p class="text-xs text-base-content/50 mt-1.5">
                Select the Kimi coding endpoint for code-optimized models
              </p>
              <label class="flex items-center gap-3 cursor-pointer mt-3">
                <input
                  type="checkbox"
                  name="step[thinking_enabled]"
                  value="true"
                  class="w-4 h-4 rounded border-base-300 text-primary focus:ring-primary/50"
                />
                <span class="text-sm">Enable Thinking Mode</span>
              </label>
              <p class="text-xs text-base-content/50 mt-1.5 ml-7">
                Uses extended reasoning for complex tasks
              </p>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-2">Temperature</label>
                <input
                  type="number"
                  name="step[temperature]"
                  step="0.1"
                  min="0"
                  max="2"
                  placeholder="Optional"
                  class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-2">Max Tokens</label>
                <input
                  type="number"
                  name="step[max_tokens]"
                  min="1"
                  placeholder="Optional"
                  class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
                />
              </div>
            </div>
            <div class="flex justify-end gap-3 pt-4 border-t border-base-300/50">
              <button
                type="button"
                phx-click={JS.patch(~p"/routers/#{@router}")}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">Add Step</button>
            </div>
          </form>
        </.modal>
      </div>
      <!-- close content z-10 wrapper -->
    </div>
    """
  end

  defp success_rate(%{total_requests: 0}), do: "-"

  defp success_rate(%{total_requests: total, successful_requests: success}) do
    "#{round(success / total * 100)}%"
  end

  defp success_color(%{total_requests: 0}), do: ""

  defp success_color(%{total_requests: total, successful_requests: success}) do
    rate = success / total * 100

    cond do
      rate >= 95 -> ""
      rate >= 80 -> "text-warning"
      true -> "text-error"
    end
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_latency(nil), do: "-"
  defp format_latency(%Decimal{} = ms), do: "#{ms |> Decimal.round(0) |> Decimal.to_integer()}ms"
  defp format_latency(ms), do: "#{round(ms)}ms"

  defp event_class(%{status: :success}), do: "bg-success/10"
  defp event_class(%{status: :fallback}), do: "bg-warning/10"
  defp event_class(_), do: "bg-error/10"

  defp event_dot_class(%{status: :success}), do: "bg-success"
  defp event_dot_class(%{status: :fallback}), do: "bg-warning"
  defp event_dot_class(_), do: "bg-error"

  defp status_badge_class("success"), do: "bg-success/20 text-success"
  defp status_badge_class("fallback"), do: "bg-warning/20 text-warning"
  defp status_badge_class("error"), do: "bg-error/20 text-error"
  defp status_badge_class("pending"), do: "bg-info/20 text-info"
  defp status_badge_class(_), do: "bg-base-300 text-base-content/60"

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp base_url do
    DodoRouterWeb.Endpoint.url()
  end

  defp snippet_for_tab("curl", base_url, slug), do: curl_snippet(base_url, slug)
  defp snippet_for_tab("python", base_url, slug), do: python_snippet(base_url, slug)
  defp snippet_for_tab("node", base_url, slug), do: node_snippet(base_url, slug)
  defp snippet_for_tab(_, base_url, slug), do: curl_snippet(base_url, slug)

  defp curl_snippet(base_url, slug) do
    """
    curl #{base_url}/r/#{slug}/v1/chat/completions \\
      -H "Authorization: Bearer YOUR_API_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{"messages": [{"role": "user", "content": "Hello!"}]}'
    """
  end

  defp python_snippet(base_url, slug) do
    """
    from openai import OpenAI

    client = OpenAI(
        base_url="#{base_url}/r/#{slug}/v1",
        api_key="YOUR_API_KEY"
    )

    response = client.chat.completions.create(
        model="default",  # model is set by routing
        messages=[{"role": "user", "content": "Hello!"}]
    )
    print(response.choices[0].message.content)
    """
  end

  defp node_snippet(base_url, slug) do
    """
    import OpenAI from 'openai';

    const client = new OpenAI({
      baseURL: '#{base_url}/r/#{slug}/v1',
      apiKey: 'YOUR_API_KEY'
    });

    const response = await client.chat.completions.create({
      model: 'default',  // model is set by routing
      messages: [{ role: 'user', content: 'Hello!' }]
    });
    console.log(response.choices[0].message.content);
    """
  end

  defp matching_keys(provider_keys, %{provider: provider, plan_type: plan_type}) do
    expected_slug = Registry.to_key_slug(provider, plan_type || "standard")

    Enum.filter(provider_keys, fn key ->
      key.provider_slug == expected_slug
    end)
  end

  defp swap_at(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end
end
