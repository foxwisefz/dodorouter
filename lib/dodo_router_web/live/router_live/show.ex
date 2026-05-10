defmodule DodoRouterWeb.RouterLive.Show do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.Routers
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer
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
      |> assign(:api_format, "openai_chat")
      |> assign(:code_language, "curl")
      |> assign(:connect_collapsed, true)
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
  def handle_event("set_api_format", %{"format" => format}, socket) do
    {:noreply, assign(socket, :api_format, format)}
  end

  def handle_event("set_code_language", %{"language" => language}, socket) do
    {:noreply, assign(socket, :code_language, language)}
  end

  def handle_event("toggle_connect", _params, socket) do
    {:noreply, assign(socket, :connect_collapsed, !socket.assigns.connect_collapsed)}
  end

  def handle_event(
        "toggle_fail_on_context_overflow",
        %{
          "fail_on_context_overflow" => value
        },
        socket
      ) do
    enabled = value == "true"

    case Routers.update_router(socket.assigns.router, %{
           "fail_on_context_overflow" => enabled
         }) do
      {:ok, router} ->
        {:noreply, assign(socket, :router, router)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
  end

  def handle_event("toggle_fail_on_context_overflow", _params, socket) do
    case Routers.update_router(socket.assigns.router, %{
           "fail_on_context_overflow" => false
         }) do
      {:ok, router} ->
        {:noreply, assign(socket, :router, router)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update setting")}
    end
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
    <div id="router-show-page" class="relative overflow-hidden">
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
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/routers/#{@router}/recordings"}
              class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
            >
              <.icon name="hero-stop-circle" class="size-4" /> Recordings
            </.link>
            <.link
              navigate={~p"/routers/#{@router}/sessions"}
              class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2"
            >
              <.icon name="hero-video-camera" class="size-4" /> Sessions
            </.link>
          </div>
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
        
    <!-- Connect -->
        <div class="card-bordered mb-8">
          <div class="flex items-center justify-between mb-0">
            <button
              phx-click="toggle_connect"
              class="flex items-center gap-2 group"
            >
              <h2 class="section-title mb-0 group-hover:text-primary transition-colors">Connect</h2>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class={"h-4 w-4 text-base-content/40 transition-transform duration-200 #{if @connect_collapsed, do: "-rotate-90", else: ""}"}
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

          <div :if={!@connect_collapsed} class="mt-3 space-y-4">
            <!-- Format selector -->
            <div class="flex bg-base-200 rounded-lg p-1 gap-1">
              <button
                phx-click="set_api_format"
                phx-value-format="openai_chat"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @api_format == "openai_chat", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                OpenAI Chat
              </button>
              <button
                phx-click="set_api_format"
                phx-value-format="openai_responses"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @api_format == "openai_responses", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                OpenAI Responses
              </button>
              <button
                phx-click="set_api_format"
                phx-value-format="anthropic"
                class={"px-3 py-1 rounded text-sm transition-colors #{if @api_format == "anthropic", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
              >
                Anthropic
              </button>
            </div>
            
    <!-- Endpoint URL -->
            <div class="p-3 rounded-lg bg-base-200/50 border border-base-300/30">
              <div class="flex items-center gap-2 mb-1.5">
                <span class={"px-2 py-0.5 rounded text-xs font-medium #{format_badge_class(@api_format)}"}>
                  {format_label(@api_format)}
                </span>
                <span class="text-sm font-medium text-base-content/80">
                  {format_name(@api_format)}
                </span>
              </div>
              <code class="block p-2.5 bg-base-300 rounded-lg font-mono text-sm text-base-content/70 break-all">
                {endpoint_url(@api_format, base_url(), @router.slug)}
              </code>
            </div>
            
    <!-- Language selector -->
            <div class="flex items-center justify-between">
              <div class="flex bg-base-200 rounded-lg p-1 gap-1">
                <button
                  phx-click="set_code_language"
                  phx-value-language="curl"
                  class={"px-3 py-1 rounded text-sm transition-colors #{if @code_language == "curl", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
                >
                  cURL
                </button>
                <button
                  phx-click="set_code_language"
                  phx-value-language="python"
                  class={"px-3 py-1 rounded text-sm transition-colors #{if @code_language == "python", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
                >
                  Python
                </button>
                <button
                  phx-click="set_code_language"
                  phx-value-language="node"
                  class={"px-3 py-1 rounded text-sm transition-colors #{if @code_language == "node", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
                >
                  Node.js
                </button>
              </div>
            </div>
            
    <!-- Code snippet -->
            <div class="code-block">
              <pre class="text-xs text-base-content/80"><code><%= raw(snippet(@api_format, @code_language, base_url(), @router.slug)) %></code></pre>
            </div>

            <p class="text-sm text-base-content/50">
              Replace <code class="text-primary font-medium">YOUR_API_KEY</code>
              with your router API key:
              <code class="font-mono text-base-content/70">{@router.api_key_prefix}...</code>
              <.link navigate={~p"/api-keys"} class="text-accent hover:underline ml-1">
                Manage keys
              </.link>
            </p>
          </div>
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
            <div class="flex items-center gap-4">
              <form phx-change="toggle_fail_on_context_overflow" class="flex items-center gap-2">
                <label class="relative inline-flex items-center cursor-pointer">
                  <input
                    type="checkbox"
                    name="fail_on_context_overflow"
                    value="true"
                    checked={@router.fail_on_context_overflow}
                    class="sr-only peer"
                  />
                  <div class="w-9 h-5 bg-base-300 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-4 after:w-4 after:transition-all peer-checked:bg-primary">
                  </div>
                  <span class="ml-2 text-sm text-base-content/70">
                    Skip fallback on context overflow
                  </span>
                </label>
                <div class="relative group">
                  <.icon
                    name="hero-question-mark-circle"
                    class="size-4 text-base-content/40 cursor-help"
                  />
                  <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block w-64 p-2 text-xs bg-base-100 border border-base-300 rounded-lg shadow-lg text-base-content/80 z-50">
                    When enabled, requests that exceed a model's context window will skip the fallback chain and fail immediately.
                  </div>
                </div>
              </form>
              <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-primary btn-sm">
                Add Step
              </.link>
            </div>
          </div>
          <div id="routing-steps" phx-update="stream" class="relative">
            <div
              :for={{dom_id, step} <- @streams.routing_steps}
              id={dom_id}
              data-step-id={step.id}
              data-step-index={step.position}
              class="step-card-wrapper"
            >
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
                    <div class="w-5 h-5 rounded flex items-center justify-center shrink-0 bg-base-200">
                      <.provider_logo
                        slug={Registry.to_key_slug(step.provider, step.plan_type)}
                        class="w-3.5 h-3.5"
                      />
                    </div>
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
                "block p-3 rounded-lg text-sm transition-colors",
                log.status == "pending" && "bg-info/10 animate-pulse",
                log.status == "success" && "bg-success/10 hover:bg-success/20",
                log.status == "fallback" && "bg-warning/10 hover:bg-warning/20",
                log.status == "error" && "bg-error/10 hover:bg-error/20"
              ]}
            >
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
                    {call_type_label(log.call_type)}
                  </span>
                  <span class={[
                    "px-1.5 py-0.5 rounded text-xs font-medium",
                    status_badge_class(log.status)
                  ]}>
                    {log.status}
                  </span>
                </div>
                <div class="flex items-center gap-4 text-base-content/50 text-sm shrink-0">
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
            </.link>
          </div>
          <p :if={!@has_logs} class="empty-state py-8">
            No requests yet. Expand the Connect section above to see how to make your first request.
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
                <div class="flex items-center gap-2">
                  <div class="w-4 h-4 rounded flex items-center justify-center shrink-0 bg-base-200">
                    <.provider_logo slug={normalize_slug(event.provider)} class="w-3 h-3" />
                  </div>
                  <span class="font-mono text-base-content/80">{event.provider}/{event.model}</span>
                </div>
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

  defp call_type_label("completion"), do: "chat"
  defp call_type_label("tool_call"), do: "tools"
  defp call_type_label("tool_enabled_completion"), do: "chat+tools"
  defp call_type_label(other), do: other

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

  defp base_url do
    DodoRouterWeb.Endpoint.url()
  end

  defp format_badge_class("openai_chat"), do: "bg-green-500/20 text-green-600"
  defp format_badge_class("openai_responses"), do: "bg-green-500/20 text-green-600"
  defp format_badge_class("anthropic"), do: "bg-orange-500/20 text-orange-600"
  defp format_badge_class(_), do: "bg-base-300 text-base-content/60"

  defp format_label("openai_chat"), do: "OpenAI"
  defp format_label("openai_responses"), do: "OpenAI"
  defp format_label("anthropic"), do: "Anthropic"
  defp format_label(_), do: "Unknown"

  defp format_name("openai_chat"), do: "Chat Completions"
  defp format_name("openai_responses"), do: "Responses API"
  defp format_name("anthropic"), do: "Messages"
  defp format_name(_), do: "Unknown"

  defp endpoint_url("openai_chat", base_url, slug),
    do: "#{base_url}/r/#{slug}/v1/chat/completions"

  defp endpoint_url("openai_responses", base_url, slug), do: "#{base_url}/r/#{slug}/v1/responses"
  defp endpoint_url("anthropic", base_url, slug), do: "#{base_url}/r/#{slug}/v1/messages"
  defp endpoint_url(_, base_url, slug), do: "#{base_url}/r/#{slug}/v1/chat/completions"

  defp snippet(format, language, base_url, slug) do
    case {format, language} do
      {"openai_chat", "curl"} -> openai_chat_curl(base_url, slug)
      {"openai_chat", "python"} -> openai_chat_python(base_url, slug)
      {"openai_chat", "node"} -> openai_chat_node(base_url, slug)
      {"openai_responses", "curl"} -> openai_responses_curl(base_url, slug)
      {"openai_responses", "python"} -> openai_responses_python(base_url, slug)
      {"openai_responses", "node"} -> openai_responses_node(base_url, slug)
      {"anthropic", "curl"} -> anthropic_curl(base_url, slug)
      {"anthropic", "python"} -> anthropic_python(base_url, slug)
      {"anthropic", "node"} -> anthropic_node(base_url, slug)
      _ -> openai_chat_curl(base_url, slug)
    end
  end

  defp openai_chat_curl(base_url, slug) do
    """
    curl #{base_url}/r/#{slug}/v1/chat/completions \\
      -H "Authorization: Bearer YOUR_API_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{"messages": [{"role": "user", "content": "Hello!"}]}'
    """
  end

  defp openai_chat_python(base_url, slug) do
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

  defp openai_chat_node(base_url, slug) do
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

  defp openai_responses_curl(base_url, slug) do
    """
    curl #{base_url}/r/#{slug}/v1/responses \\
      -H "Authorization: Bearer YOUR_API_KEY" \\
      -H "Content-Type: application/json" \\
      -d '{"input": "Hello!"}'
    """
  end

  defp openai_responses_python(base_url, slug) do
    """
    from openai import OpenAI

    client = OpenAI(
        base_url="#{base_url}/r/#{slug}/v1",
        api_key="YOUR_API_KEY"
    )

    response = client.responses.create(
        model="default",  # model is set by routing
        input="Hello!"
    )
    print(response.output_text)
    """
  end

  defp openai_responses_node(base_url, slug) do
    """
    import OpenAI from 'openai';

    const client = new OpenAI({
      baseURL: '#{base_url}/r/#{slug}/v1',
      apiKey: 'YOUR_API_KEY'
    });

    const response = await client.responses.create({
      model: 'default',  // model is set by routing
      input: 'Hello!'
    });
    console.log(response.output_text);
    """
  end

  defp anthropic_curl(base_url, slug) do
    """
    curl #{base_url}/r/#{slug}/v1/messages \\
      -H "x-api-key: YOUR_API_KEY" \\
      -H "Content-Type: application/json" \\
      -H "anthropic-version: 2023-06-01" \\
      -d '{
        "model": "default",
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": "Hello!"}]
      }'
    """
  end

  defp anthropic_python(base_url, slug) do
    """
    import anthropic

    client = anthropic.Anthropic(
        base_url="#{base_url}/r/#{slug}/v1",
        api_key="YOUR_API_KEY"
    )

    response = client.messages.create(
        model="default",  # model is set by routing
        max_tokens=1024,
        messages=[{"role": "user", "content": "Hello!"}]
    )
    print(response.content[0].text)
    """
  end

  defp anthropic_node(base_url, slug) do
    """
    import Anthropic from '@anthropic-ai/sdk';

    const client = new Anthropic({
      baseURL: '#{base_url}/r/#{slug}/v1',
      apiKey: 'YOUR_API_KEY'
    });

    const response = await client.messages.create({
      model: 'default',  // model is set by routing
      max_tokens: 1024,
      messages: [{ role: 'user', content: 'Hello!' }]
    });
    console.log(response.content[0].text);
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
