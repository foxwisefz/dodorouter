defmodule DodoRouterWeb.LogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    log = Logs.get_log!(id)

    socket =
      socket
      |> assign(:page_title, "Request #{String.slice(log.request_id, 0, 8)}...")
      |> assign(:log, log)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Header -->
      <div class="flex items-center gap-4 mb-6">
        <.link navigate={~p"/logs"} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">Request Details</h1>
          <code class="text-sm text-base-content/60"><%= @log.request_id %></code>
        </div>
      </div>

      <!-- Overview Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-4 mb-6">
        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Status</div>
          <div class="stat-value text-lg"><.status_badge status={@log.status} /></div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Provider</div>
          <div class="stat-value text-lg"><%= @log.final_provider %></div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Model</div>
          <div class="stat-value text-sm font-mono"><%= @log.final_model %></div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Latency</div>
          <div class="stat-value text-lg"><%= @log.latency_ms || "-" %>ms</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Tokens</div>
          <div class="stat-value text-lg"><%= @log.total_tokens || "-" %></div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Cost</div>
          <div class="stat-value text-lg">
            <%= if @log.estimated_cost_usd, do: "$#{Decimal.round(@log.estimated_cost_usd, 4)}", else: "-" %>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
        <!-- Performance Card -->
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-base">Performance</h2>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <tbody>
                  <tr>
                    <td class="text-base-content/60">Call Type</td>
                    <td class="text-right"><.call_type_badge type={@log.call_type} /></td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Total Latency</td>
                    <td class="text-right font-mono"><%= @log.latency_ms || "-" %> ms</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Time to First Byte</td>
                    <td class="text-right font-mono"><%= @log.ttfb_ms || "-" %> ms</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Prompt Tokens</td>
                    <td class="text-right font-mono"><%= @log.prompt_tokens || "-" %></td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Completion Tokens</td>
                    <td class="text-right font-mono"><%= @log.completion_tokens || "-" %></td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Timestamp</td>
                    <td class="text-right font-mono text-xs"><%= format_datetime(@log.inserted_at) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Routing Chain Card -->
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-base">Routing Chain</h2>
            <ul class="steps steps-vertical">
              <%= for {attempt, idx} <- Enum.with_index(@log.attempted_steps) do %>
                <li class={"step #{if attempt["status"] == "success", do: "step-success", else: "step-error"}"}>
                  <div class="text-left w-full">
                    <div class="flex items-center gap-2">
                      <span class="font-medium"><%= attempt["provider"] %></span>
                      <span class="text-base-content/60 text-sm">/ <%= attempt["model"] %></span>
                    </div>
                    <div class="text-sm text-base-content/60 mt-1">
                      <span class={"font-medium #{if attempt["status"] == "success", do: "text-success", else: "text-error"}"}>
                        <%= attempt["status"] %>
                      </span>
                      <span class="mx-2">·</span>
                      <span><%= attempt["latency_ms"] %>ms</span>
                    </div>
                    <div :if={attempt["error"]} class="text-sm text-error mt-1">
                      <%= attempt["error"] %>
                    </div>
                  </div>
                </li>
              <% end %>
            </ul>
          </div>
        </div>
      </div>

      <!-- Tools Invoked -->
      <div :if={length(@log.tools_invoked) > 0} class="card bg-base-100 shadow mb-6">
        <div class="card-body">
          <h2 class="card-title text-base">Tools Invoked</h2>
          <div class="flex flex-wrap gap-2">
            <span :for={tool <- @log.tools_invoked} class="badge badge-secondary badge-lg font-mono">
              <%= tool %>
            </span>
          </div>
        </div>
      </div>

      <!-- Request/Response Bodies -->
      <div :if={@log.request_body || @log.response_body} class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div :if={@log.request_body} class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-base">Request Body</h2>
            <div class="mockup-code text-xs max-h-96 overflow-auto">
              <pre><code><%= format_json(@log.request_body) %></code></pre>
            </div>
          </div>
        </div>

        <div :if={@log.response_body} class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-base">Response Body</h2>
            <div class="mockup-code text-xs max-h-96 overflow-auto">
              <pre><code><%= format_json(@log.response_body) %></code></pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
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
    <span class={"badge #{@class}"}><%= @status %></span>
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
    <span class={"badge #{@class}"}><%= @label %></span>
    """
  end

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_json(nil), do: ""

  defp format_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end
end
