defmodule DodoRouterWeb.ProjectLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Projects
  alias DodoRouter.Projects.RoutingStep
  alias DodoRouter.Logs
  alias DodoRouter.Secrets

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(socket.assigns.current_user, id) |> Projects.with_routing_steps()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DodoRouter.PubSub, "project:#{project.id}:events")
    end

    socket =
      socket
      |> assign(:project, project)
      |> assign(:stats, Logs.stats(project))
      |> assign(:recent_events, [])
      |> stream(:routing_steps, project.routing_steps)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    assign(socket, :page_title, socket.assigns.project.name)
  end

  defp apply_action(socket, :edit, _params) do
    assign(socket, :page_title, "Edit #{socket.assigns.project.name}")
  end

  defp apply_action(socket, :routing, _params) do
    socket
    |> assign(:page_title, "Routing - #{socket.assigns.project.name}")
    |> assign(:new_step, %RoutingStep{})
  end

  defp apply_action(socket, :credentials, _params) do
    assign(socket, :page_title, "Credentials - #{socket.assigns.project.name}")
  end

  @impl true
  def handle_event("add_step", %{"step" => step_params}, socket) do
    case Projects.create_routing_step(socket.assigns.project, step_params) do
      {:ok, step} ->
        {:noreply,
         socket
         |> stream_insert(:routing_steps, step)
         |> put_flash(:info, "Step added")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to add step")}
    end
  end

  def handle_event("delete_step", %{"id" => id}, socket) do
    step = Projects.get_routing_step!(id)
    {:ok, _} = Projects.delete_routing_step(step)

    {:noreply, stream_delete(socket, :routing_steps, step)}
  end

  def handle_event("save_credential", %{"provider" => provider, "api_key" => api_key}, socket) do
    project = socket.assigns.project
    secret_name = "#{provider}_api_key"

    case Secrets.put(project.id, secret_name, api_key) do
      :ok ->
        {:noreply, put_flash(socket, :info, "#{provider} API key saved")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save API key")}
    end
  end

  def handle_event("regenerate_api_key", _params, socket) do
    case Projects.regenerate_api_key(socket.assigns.project) do
      {:ok, project, api_key} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:new_api_key, api_key)
         |> put_flash(:info, "API key regenerated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate API key")}
    end
  end

  @impl true
  def handle_info({:proxy_event, event}, socket) do
    recent_events = [event | Enum.take(socket.assigns.recent_events, 9)]
    stats = Logs.stats(socket.assigns.project)

    {:noreply,
     socket
     |> assign(:recent_events, recent_events)
     |> assign(:stats, stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto">
      <.header>
        <%= @project.name %>
        <:subtitle><code class="text-sm"><%= @project.slug %></code></:subtitle>
        <:actions>
          <.link patch={~p"/projects/#{@project}/routing"}>
            <.button>Routing</.button>
          </.link>
          <.link patch={~p"/projects/#{@project}/credentials"}>
            <.button>Credentials</.button>
          </.link>
        </:actions>
      </.header>

      <div class="mt-8 grid grid-cols-4 gap-4">
        <.stat_card title="Requests (24h)" value={@stats.total_requests} />
        <.stat_card title="Success Rate" value={success_rate(@stats)} />
        <.stat_card title="Tokens Used" value={format_number(@stats.total_tokens)} />
        <.stat_card title="Avg Latency" value={format_latency(@stats.avg_latency_ms)} />
      </div>

      <div class="mt-8">
        <h3 class="text-lg font-semibold mb-4">API Endpoint</h3>
        <div class="p-4 bg-gray-50 rounded-lg">
          <code class="text-sm">POST /v1/chat/completions</code>
          <p class="mt-2 text-sm text-gray-600">
            Authorization: Bearer <code><%= @project.api_key_prefix %>...</code>
          </p>
        </div>
      </div>

      <div :if={assigns[:new_api_key]} class="mt-4 p-4 bg-base-200 border border-warning rounded-lg">
        <p class="font-semibold">New API key - save it now:</p>
        <code class="block mt-2 p-3 bg-base-300 rounded font-mono text-sm break-all select-all">
          <%= @new_api_key %>
        </code>
      </div>

      <div class="mt-8">
        <h3 class="text-lg font-semibold mb-4">Routing Chain</h3>
        <div class="space-y-2">
          <div :for={{dom_id, step} <- @streams.routing_steps} id={dom_id} class="flex items-center gap-4 p-3 bg-white border rounded-lg">
            <span class="w-8 h-8 flex items-center justify-center bg-blue-100 text-blue-800 rounded-full font-semibold">
              <%= step.position + 1 %>
            </span>
            <div class="flex-1">
              <span class="font-medium"><%= step.provider %></span>
              <span class="text-gray-500">/ <%= step.model %></span>
              <span :if={step.plan_type == "coding"} class="ml-2 text-xs bg-purple-100 text-purple-800 px-2 py-0.5 rounded">coding</span>
              <span :if={step.thinking_enabled} class="ml-2 text-xs bg-green-100 text-green-800 px-2 py-0.5 rounded">thinking</span>
            </div>
            <button
              phx-click="delete_step"
              phx-value-id={step.id}
              class="text-red-600 hover:text-red-800"
              data-confirm="Remove this step?"
            >
              Remove
            </button>
          </div>
          <p :if={Enum.empty?(@streams.routing_steps |> elem(1))} class="text-gray-500 italic">
            No routing steps configured. Add one to start proxying requests.
          </p>
        </div>
      </div>

      <div :if={length(@recent_events) > 0} class="mt-8">
        <h3 class="text-lg font-semibold mb-4">Recent Events (Live)</h3>
        <div class="space-y-2">
          <div :for={event <- @recent_events} class={"p-2 rounded text-sm #{event_class(event)}"}>
            <span class="font-mono"><%= event.provider %>/<%= event.model %></span>
            <span class="ml-4"><%= event.latency_ms %>ms</span>
            <span :if={event.had_fallback} class="ml-2 text-orange-600">(fallback)</span>
          </div>
        </div>
      </div>

      <.modal :if={@live_action == :routing} id="routing-modal" show on_cancel={JS.patch(~p"/projects/#{@project}")}>
        <.header>Add Routing Step</.header>
        <.simple_form for={%{}} phx-submit="add_step" class="mt-4">
          <.input name="step[provider]" type="select" label="Provider" options={[{"z.ai", "zai"}, {"Moonshot", "moonshot"}]} />
          <.input name="step[model]" type="text" label="Model" placeholder="glm-5.1 or kimi-k2.5" />
          <.input name="step[plan_type]" type="select" label="Plan Type (z.ai only)" options={[{"Standard", "standard"}, {"Coding", "coding"}]} />
          <.input name="step[thinking_enabled]" type="checkbox" label="Enable Thinking (Kimi K2.5)" />
          <.input name="step[temperature]" type="number" label="Temperature (optional)" step="0.1" min="0" max="2" />
          <.input name="step[max_tokens]" type="number" label="Max Tokens (optional)" min="1" />
          <:actions>
            <.button>Add Step</.button>
          </:actions>
        </.simple_form>
      </.modal>

      <.modal :if={@live_action == :credentials} id="credentials-modal" show on_cancel={JS.patch(~p"/projects/#{@project}")}>
        <.header>Provider Credentials</.header>
        <p class="text-sm text-gray-600 mt-2">API keys are stored securely in Infisical.</p>

        <div class="mt-6 space-y-6">
          <.simple_form for={%{}} phx-submit="save_credential">
            <input type="hidden" name="provider" value="zai" />
            <.input name="api_key" type="password" label="z.ai API Key" placeholder="Enter new key to update" />
            <:actions>
              <.button>Save z.ai Key</.button>
            </:actions>
          </.simple_form>

          <.simple_form for={%{}} phx-submit="save_credential">
            <input type="hidden" name="provider" value="moonshot" />
            <.input name="api_key" type="password" label="Moonshot API Key" placeholder="Enter new key to update" />
            <:actions>
              <.button>Save Moonshot Key</.button>
            </:actions>
          </.simple_form>
        </div>

        <div class="mt-8 pt-6 border-t">
          <h4 class="font-medium">DodoRouter API Key</h4>
          <p class="text-sm text-gray-600 mt-1">
            Current: <code><%= @project.api_key_prefix %>...</code>
          </p>
          <.button phx-click="regenerate_api_key" data-confirm="This will invalidate the current key. Continue?" class="mt-2">
            Regenerate API Key
          </.button>
        </div>
      </.modal>

      <.back navigate={~p"/projects"}>Back to projects</.back>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="p-4 bg-white border rounded-lg">
      <p class="text-sm text-gray-500"><%= @title %></p>
      <p class="text-2xl font-semibold mt-1"><%= @value %></p>
    </div>
    """
  end

  defp success_rate(%{total_requests: 0}), do: "-"
  defp success_rate(%{total_requests: total, successful_requests: success}) do
    "#{round(success / total * 100)}%"
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_latency(nil), do: "-"
  defp format_latency(ms), do: "#{round(ms)}ms"

  defp event_class(%{status: :success}), do: "bg-green-50"
  defp event_class(%{status: :fallback}), do: "bg-yellow-50"
  defp event_class(_), do: "bg-red-50"
end
