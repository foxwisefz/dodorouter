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
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/routers"} class="btn btn-ghost btn-sm btn-square">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
              </svg>
            </.link>
            <h1 class="text-2xl font-bold"><%= @router.name %></h1>
          </div>
          <p class="text-base-content/60 font-mono ml-10"><%= @router.slug %></p>
        </div>
        <div class="flex gap-2">
          <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-outline btn-sm">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h7" />
            </svg>
            Routing
          </.link>
          <.link navigate={~p"/providers"} class="btn btn-outline btn-sm">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z" />
            </svg>
            Providers
          </.link>
        </div>
      </div>

      <!-- New API Key Alert -->
      <div :if={assigns[:new_api_key]} class="alert alert-warning mb-6">
        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
        <div class="flex-1">
          <h3 class="font-bold">New API key generated!</h3>
          <p class="text-sm">Save it now - this won't be shown again.</p>
          <code class="block mt-2 p-3 bg-base-300 rounded font-mono text-sm break-all select-all">
            <%= @new_api_key %>
          </code>
        </div>
      </div>

      <!-- Stats -->
      <div class="stats stats-vertical sm:stats-horizontal shadow w-full mb-6">
        <div class="stat">
          <div class="stat-title">Requests (24h)</div>
          <div class="stat-value text-primary"><%= @stats.total_requests %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Success Rate</div>
          <div class={["stat-value", success_color(@stats)]}><%= success_rate(@stats) %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Tokens Used</div>
          <div class="stat-value"><%= format_number(@stats.total_tokens) %></div>
        </div>
        <div class="stat">
          <div class="stat-title">Avg Latency</div>
          <div class="stat-value"><%= format_latency(@stats.avg_latency_ms) %></div>
        </div>
      </div>

      <!-- Quick Start Card -->
      <div class="card bg-base-100 shadow mb-6">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Quick Start</h2>
            <div class="tabs tabs-boxed tabs-sm">
              <button phx-click="set_snippet_tab" phx-value-tab="curl" class={["tab", @snippet_tab == "curl" && "tab-active"]}>cURL</button>
              <button phx-click="set_snippet_tab" phx-value-tab="python" class={["tab", @snippet_tab == "python" && "tab-active"]}>Python</button>
              <button phx-click="set_snippet_tab" phx-value-tab="node" class={["tab", @snippet_tab == "node" && "tab-active"]}>Node.js</button>
            </div>
          </div>

          <div :if={@snippet_tab == "curl"} class="mockup-code text-xs mt-4">
            <pre data-prefix="$"><code><%= raw(curl_snippet(base_url(), @router.slug)) %></code></pre>
          </div>

          <div :if={@snippet_tab == "python"} class="mockup-code text-xs mt-4">
            <pre><code><%= raw(python_snippet(base_url(), @router.slug)) %></code></pre>
          </div>

          <div :if={@snippet_tab == "node"} class="mockup-code text-xs mt-4">
            <pre><code><%= raw(node_snippet(base_url(), @router.slug)) %></code></pre>
          </div>

          <p class="text-sm text-base-content/60 mt-3">
            Replace <code class="text-primary">YOUR_API_KEY</code> with your router API key: <code class="font-mono"><%= @router.api_key_prefix %>...</code>
          </p>
        </div>
      </div>

      <!-- Routing Chain -->
      <div class="card bg-base-100 shadow mb-6">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">Routing Chain</h2>
            <.link patch={~p"/routers/#{@router}/routing"} class="btn btn-primary btn-sm">
              Add Step
            </.link>
          </div>
          <div id="routing-steps" phx-update="stream" class="space-y-2 mt-4">
            <div :for={{dom_id, step} <- @streams.routing_steps} id={dom_id} class="flex items-center gap-3 p-3 bg-base-200 rounded-lg">
              <div class="badge badge-primary badge-lg font-bold">
                <%= step.position + 1 %>
              </div>
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <span class="font-medium"><%= step.provider %></span>
                  <span class="text-base-content/60">/</span>
                  <span class="font-mono text-sm"><%= step.model %></span>
                  <span :if={step.plan_type == "coding"} class="badge badge-secondary badge-sm">coding</span>
                  <span :if={step.thinking_enabled} class="badge badge-accent badge-sm">thinking</span>
                </div>
                <div class="mt-1">
                  <select
                    phx-change="assign_key"
                    name="key_id"
                    class={"select select-xs #{if step.provider_key_id, do: "", else: "select-warning"}"}
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
              <div class="flex flex-col gap-0.5">
                <button
                  phx-click="move_step_up"
                  phx-value-id={step.id}
                  class="btn btn-ghost btn-xs btn-square"
                  title="Move up"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7" />
                  </svg>
                </button>
                <button
                  phx-click="move_step_down"
                  phx-value-id={step.id}
                  class="btn btn-ghost btn-xs btn-square"
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
                class="btn btn-ghost btn-sm btn-square text-error"
                data-confirm="Remove this step?"
              >
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                </svg>
              </button>
            </div>
          </div>
          <p :if={!@has_routing_steps} class="text-base-content/50 text-center py-8">
            No routing steps configured. Add one to start proxying requests.
          </p>
        </div>
      </div>

      <!-- Live Events -->
      <div :if={length(@recent_events) > 0} class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center gap-2">
            <h2 class="card-title text-base">Recent Events</h2>
            <span class="badge badge-success badge-sm gap-1">
              <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
              Live
            </span>
          </div>
          <div class="space-y-2 mt-4">
            <div :for={event <- @recent_events} class={"flex items-center justify-between p-2 rounded text-sm #{event_class(event)}"}>
              <div class="flex items-center gap-2">
                <span class={"w-2 h-2 rounded-full #{event_dot_class(event)}"}></span>
                <span class="font-mono"><%= event.provider %>/<%= event.model %></span>
                <span :if={event.had_fallback} class="badge badge-warning badge-xs">fallback</span>
              </div>
              <span class="text-base-content/60"><%= event.latency_ms %>ms</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Routing Modal -->
      <.modal :if={@live_action == :routing} id="routing-modal" show on_cancel={JS.patch(~p"/routers/#{@router}")}>
        <h3 class="font-bold text-lg mb-4">Add Routing Step</h3>
        <form phx-submit="add_step" phx-change="update_step_form" class="space-y-4">
          <div class="form-control">
            <label class="label"><span class="label-text">Provider</span></label>
            <select name="step[provider]" class="select select-bordered w-full" required>
              <option value="zai" selected={@step_provider == "zai"}>z.ai (GLM models)</option>
              <option value="moonshot" selected={@step_provider == "moonshot"}>Moonshot (Kimi K2.5)</option>
            </select>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Model</span></label>
            <input
              type="text"
              name="step[model]"
              placeholder={if @step_provider == "zai", do: "e.g. glm-4-plus, glm-5.1", else: "e.g. kimi-k2.5"}
              class="input input-bordered w-full"
              required
            />
          </div>

          <!-- z.ai specific options -->
          <div :if={@step_provider == "zai"} class="form-control">
            <label class="label"><span class="label-text">Plan Type</span></label>
            <select name="step[plan_type]" class="select select-bordered w-full">
              <option value="standard">Standard (/api/paas/v4)</option>
              <option value="coding">Coding Plan (/api/coding/paas/v4)</option>
            </select>
            <label class="label"><span class="label-text-alt text-base-content/50">Select based on your z.ai subscription</span></label>
          </div>

          <!-- Moonshot specific options -->
          <div :if={@step_provider == "moonshot"} class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <input type="checkbox" name="step[thinking_enabled]" value="true" class="checkbox checkbox-primary" />
              <span class="label-text">Enable Thinking Mode</span>
            </label>
            <label class="label"><span class="label-text-alt text-base-content/50">Uses extended reasoning for complex tasks</span></label>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Temperature</span></label>
              <input type="number" name="step[temperature]" step="0.1" min="0" max="2" placeholder="Optional" class="input input-bordered w-full" />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Max Tokens</span></label>
              <input type="number" name="step[max_tokens]" min="1" placeholder="Optional" class="input input-bordered w-full" />
            </div>
          </div>
          <div class="modal-action">
            <button type="button" phx-click={JS.patch(~p"/routers/#{@router}")} class="btn">Cancel</button>
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
      rate >= 99 -> "text-success"
      rate >= 95 -> "text-warning"
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
