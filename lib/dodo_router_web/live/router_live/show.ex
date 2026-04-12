defmodule DodoRouterWeb.RouterLive.Show do
  use DodoRouterWeb, :live_view

  require Logger

  alias DodoRouter.Routers
  alias DodoRouter.Routers.RoutingStep
  alias DodoRouter.Logs
  alias DodoRouter.Providers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    router = Routers.get_router!(socket.assigns.current_user, id) |> Routers.with_routing_steps()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "router:#{router.id}:events")
    end

    provider_keys = Providers.list_provider_keys(socket.assigns.current_user)

    socket =
      socket
      |> assign(:router, router)
      |> assign(:stats, Logs.stats(router))
      |> assign(:recent_events, [])
      |> assign(:stats_timer, nil)
      |> assign(:has_routing_steps, length(router.routing_steps) > 0)
      |> assign(:snippet_tab, "curl")
      |> assign(:provider_keys, provider_keys)
      |> stream(:routing_steps, router.routing_steps)

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

  defp swap_at(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end

  def handle_event("assign_key", %{"step_id" => step_id, "key_id" => key_id}, socket) do
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
  def handle_info({:proxy_event, event}, socket) do
    recent_events = [event | Enum.take(socket.assigns.recent_events, 9)]

    # Debounce stats refresh - schedule it, cancel previous timer
    if socket.assigns[:stats_timer], do: Process.cancel_timer(socket.assigns[:stats_timer])
    timer = Process.send_after(self(), :refresh_stats, 500)

    {:noreply,
     socket
     |> assign(:recent_events, recent_events)
     |> assign(:stats_timer, timer)}
  end

  def handle_info(:refresh_stats, socket) do
    stats = Logs.stats(socket.assigns.router)
    {:noreply, assign(socket, :stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
        <div>
          <div class="flex items-center gap-3">
            <.link navigate={~p"/routers"} class="p-2 rounded-lg hover:bg-base-200 transition-colors text-base-content/60 hover:text-base-content">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
              </svg>
            </.link>
            <div>
              <h1 class="text-2xl font-bold"><%= @router.name %></h1>
              <p class="text-base-content/50 font-mono text-sm"><%= @router.slug %></p>
            </div>
          </div>
        </div>
        <div class="flex gap-2">
          <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h7" />
            </svg>
            Routing
          </.link>
          <.link navigate={~p"/providers"} class="btn btn-sm bg-base-200 border-base-300/50 hover:bg-base-300 gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
            </svg>
            Providers
          </.link>
        </div>
      </div>

      <!-- New API Key Alert -->
      <div :if={assigns[:new_api_key]} class="card-bordered p-4 mb-6 border-warning/50 bg-warning/5">
        <div class="flex gap-3">
          <div class="stat-icon bg-warning/10 text-warning flex-shrink-0">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
          </div>
          <div class="flex-1">
            <h3 class="font-semibold text-warning">New API key generated!</h3>
            <p class="text-sm text-base-content/60">Save it now - this won't be shown again.</p>
            <code class="block mt-2 p-3 bg-base-300 rounded-lg font-mono text-sm break-all select-all">
              <%= @new_api_key %>
            </code>
          </div>
        </div>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        <div class="stat-card">
          <div class="stat-label">Requests (24h)</div>
          <div class="stat-value"><%= @stats.total_requests %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Success Rate</div>
          <div class={["stat-value", success_color(@stats)]}><%= success_rate(@stats) %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Tokens Used</div>
          <div class="stat-value"><%= format_number(@stats.total_tokens) %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Avg Latency</div>
          <div class="stat-value"><%= format_latency(@stats.avg_latency_ms) %></div>
        </div>
      </div>

      <!-- Quick Start Card -->
      <div class="card-bordered p-5 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="section-title mb-0">Quick Start</h2>
          <div class="flex bg-base-200 rounded-lg p-1 gap-1">
            <button
              phx-click="set_snippet_tab"
              phx-value-tab="curl"
              class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "curl", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
            >cURL</button>
            <button
              phx-click="set_snippet_tab"
              phx-value-tab="python"
              class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "python", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
            >Python</button>
            <button
              phx-click="set_snippet_tab"
              phx-value-tab="node"
              class={"px-3 py-1 rounded text-sm transition-colors #{if @snippet_tab == "node", do: "bg-base-100 text-base-content", else: "text-base-content/60 hover:text-base-content"}"}
            >Node.js</button>
          </div>
        </div>

        <div class="code-block">
          <pre class="text-xs text-base-content/80"><code><%= raw(snippet_for_tab(@snippet_tab, base_url(), @router.slug)) %></code></pre>
        </div>

        <p class="text-sm text-base-content/50 mt-3">
          Replace <code class="text-primary font-medium">YOUR_API_KEY</code> with your router API key: <code class="font-mono text-base-content/70"><%= @router.api_key_prefix %>...</code>
        </p>
      </div>

      <!-- Routing Chain -->
      <div class="card-bordered p-5 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="section-title mb-0">Routing Chain</h2>
          <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-primary btn-sm">
            Add Step
          </.link>
        </div>
        <div id="routing-steps" phx-update="stream" class="space-y-3">
          <div :for={{dom_id, step} <- @streams.routing_steps} id={dom_id} class="step-card flex items-center gap-4">
            <div class="w-8 h-8 rounded-lg bg-primary/20 text-primary flex items-center justify-center font-bold text-sm flex-shrink-0">
              <%= step.position + 1 %>
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="font-medium text-base-content/90"><%= step.provider %></span>
                <span class="text-base-content/40">/</span>
                <span class="font-mono text-sm text-base-content/70"><%= step.model %></span>
                <span :if={step.plan_type == "coding"} class="px-1.5 py-0.5 rounded text-xs bg-secondary/20 text-secondary">coding</span>
                <span :if={step.thinking_enabled} class="px-1.5 py-0.5 rounded text-xs bg-accent/20 text-accent">thinking</span>
              </div>
              <div class="mt-2">
                <select
                  phx-change="assign_key"
                  name="key_id"
                  class={"text-sm py-1.5 px-2 rounded-lg border transition-colors #{if step.provider_key_id, do: "bg-base-200/50 border-base-300/30 text-base-content/70", else: "bg-warning/5 border-warning/30 text-warning"}"}
                >
                  <input type="hidden" name="step_id" value={step.id} />
                  <option value="">-- Select API Key --</option>
                  <%= for key <- @provider_keys do %>
                    <option value={key.id} selected={step.provider_key_id == key.id}>
                      <%= key.label %> (<%= key.provider_slug %>)
                    </option>
                  <% end %>
                </select>
              </div>
            </div>
            <div class="flex flex-col gap-1">
              <button
                phx-click="move_step_up"
                phx-value-id={step.id}
                class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors"
                title="Move up"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7" />
                </svg>
              </button>
              <button
                phx-click="move_step_down"
                phx-value-id={step.id}
                class="p-1 rounded hover:bg-base-300 text-base-content/40 hover:text-base-content transition-colors"
                title="Move down"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                </svg>
              </button>
            </div>
            <button
              phx-click="delete_step"
              phx-value-id={step.id}
              class="p-2 rounded-lg hover:bg-error/10 text-base-content/40 hover:text-error transition-colors"
              data-confirm="Remove this step?"
            >
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
              </svg>
            </button>
          </div>
        </div>
        <p :if={!@has_routing_steps} class="empty-state py-8">
          No routing steps configured. Add one to start proxying requests.
        </p>
      </div>

      <!-- Live Events -->
      <div :if={length(@recent_events) > 0} class="card-bordered p-5">
        <div class="flex items-center gap-3 mb-4">
          <h2 class="section-title mb-0">Recent Events</h2>
          <span class="flex items-center gap-1.5 px-2 py-0.5 bg-success/10 rounded text-xs font-medium text-success">
            <span class="live-dot"></span>
            Live
          </span>
        </div>
        <div class="space-y-2">
          <div :for={event <- @recent_events} class={"flex items-center justify-between p-3 rounded-lg text-sm #{event_class(event)}"}>
            <div class="flex items-center gap-3">
              <span class={"w-2 h-2 rounded-full #{event_dot_class(event)}"}></span>
              <span class="font-mono text-base-content/80"><%= event.provider %>/<%= event.model %></span>
              <span :if={event.had_fallback} class="px-1.5 py-0.5 bg-warning/20 text-warning rounded text-xs">fallback</span>
            </div>
            <span class="text-base-content/50 font-mono"><%= event.latency_ms %>ms</span>
          </div>
        </div>
      </div>

      <!-- Routing Modal -->
      <.modal :if={@live_action == :routing} id="routing-modal" show on_cancel={JS.patch(~p"/routers/#{@router}")}>
        <h3 class="text-lg font-semibold mb-6">Add Routing Step</h3>
        <form phx-submit="add_step" phx-change="update_step_form" class="space-y-5">
          <div>
            <label class="block text-sm font-medium text-base-content/70 mb-2">Provider</label>
            <select name="step[provider]" class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg" required>
              <option value="zai" selected={@step_provider == "zai"}>z.ai (GLM models)</option>
              <option value="moonshot" selected={@step_provider == "moonshot"}>Moonshot (Kimi K2.5)</option>
            </select>
          </div>
          <div>
            <label class="block text-sm font-medium text-base-content/70 mb-2">Model</label>
            <input
              type="text"
              name="step[model]"
              placeholder={if @step_provider == "zai", do: "e.g. glm-4-plus, glm-5.1", else: "e.g. kimi-k2.5"}
              class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg"
              required
            />
          </div>

          <!-- z.ai specific options -->
          <div :if={@step_provider == "zai"}>
            <label class="block text-sm font-medium text-base-content/70 mb-2">Plan Type</label>
            <select name="step[plan_type]" class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg">
              <option value="standard">Standard (/api/paas/v4)</option>
              <option value="coding">Coding Plan (/api/coding/paas/v4)</option>
            </select>
            <p class="text-xs text-base-content/50 mt-1.5">Select based on your z.ai subscription</p>
          </div>

          <!-- Moonshot specific options -->
          <div :if={@step_provider == "moonshot"}>
            <label class="flex items-center gap-3 cursor-pointer">
              <input type="checkbox" name="step[thinking_enabled]" value="true" class="w-4 h-4 rounded border-base-300 text-primary focus:ring-primary/50" />
              <span class="text-sm">Enable Thinking Mode</span>
            </label>
            <p class="text-xs text-base-content/50 mt-1.5 ml-7">Uses extended reasoning for complex tasks</p>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Temperature</label>
              <input type="number" name="step[temperature]" step="0.1" min="0" max="2" placeholder="Optional" class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg" />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-2">Max Tokens</label>
              <input type="number" name="step[max_tokens]" min="1" placeholder="Optional" class="w-full py-2.5 px-3 bg-base-200 border border-base-300/50 rounded-lg" />
            </div>
          </div>
          <div class="flex justify-end gap-3 pt-4 border-t border-base-300/50">
            <button type="button" phx-click={JS.patch(~p"/routers/#{@router}")} class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Add Step</button>
          </div>
        </form>
      </.modal>
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
end
