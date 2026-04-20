defmodule DodoRouterWeb.LogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Try by primary key first, then by request_id (for live stream links)
    log =
      case Logs.get_log(socket.assigns.current_user, id) do
        nil -> Logs.get_log_by_request_id!(socket.assigns.current_user, id)
        log -> log
      end

    socket =
      socket
      |> assign(:page_title, "Request #{String.slice(log.request_id, 0, 8)}...")
      |> assign(:log, log)

    {:ok, socket}
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
        <div>
          <h1 class="text-2xl font-bold">Request Details</h1>
          <code class="text-sm text-base-content/60">{@log.request_id}</code>
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
          <div class="stat-value text-lg">{@log.final_provider}</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Model</div>
          <div class="stat-value text-sm font-mono">{@log.final_model}</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Latency</div>
          <div class="stat-value text-lg">{@log.latency_ms || "-"}ms</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Tokens</div>
          <div class="stat-value text-lg">{@log.total_tokens || "-"}</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow p-4">
          <div class="stat-title text-xs">Cost</div>
          <div class="stat-value text-lg">
            {if @log.estimated_cost_usd,
              do: "$#{Decimal.round(@log.estimated_cost_usd, 4)}",
              else: "-"}
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
                    <td class="text-right font-mono">{@log.latency_ms || "-"} ms</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Provider Time</td>
                    <td class="text-right font-mono">{provider_time(@log)} ms</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">DodoRouter Overhead</td>
                    <td class="text-right">
                      <span class="font-mono">{overhead_time(@log)} ms</span>
                      <span class="text-success text-xs ml-1">({overhead_percent(@log)})</span>
                    </td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Time to First Byte</td>
                    <td class="text-right font-mono">{@log.ttfb_ms || "-"} ms</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Prompt Tokens</td>
                    <td class="text-right font-mono">{@log.prompt_tokens || "-"}</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Completion Tokens</td>
                    <td class="text-right font-mono">{@log.completion_tokens || "-"}</td>
                  </tr>
                  <tr>
                    <td class="text-base-content/60">Timestamp</td>
                    <td class="text-right font-mono text-xs">{format_datetime(@log.inserted_at)}</td>
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
            <div class="space-y-4 mt-2">
              <%= for {attempt, idx} <- Enum.with_index(@log.attempted_steps) do %>
                <div class={[
                  "p-3 rounded-lg border-l-4",
                  attempt["status"] == "success" && "bg-success/10 border-success",
                  attempt["status"] != "success" && "bg-error/10 border-error"
                ]}>
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="badge badge-neutral">{idx + 1}</span>
                      <span class="font-medium">{attempt["provider"]}</span>
                      <span class="text-base-content/60">/ {attempt["model"]}</span>
                      <span
                        :if={attempt["plan_type"] == "coding"}
                        class="badge badge-secondary badge-sm"
                      >
                        coding
                      </span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span :if={attempt["http_status"]} class="badge badge-ghost badge-sm">
                        HTTP {attempt["http_status"]}
                      </span>
                      <span class={[
                        "badge badge-sm",
                        attempt["status"] == "success" && "badge-success",
                        attempt["status"] != "success" && "badge-error"
                      ]}>
                        {attempt["status"]}
                      </span>
                      <span class="font-mono text-sm">{attempt["latency_ms"]}ms</span>
                    </div>
                  </div>
                  <div :if={attempt["endpoint"]} class="mt-2">
                    <code class="text-xs text-base-content/70 break-all">{attempt["endpoint"]}</code>
                  </div>
                  <div :if={attempt["error"]} class="mt-2 text-sm text-error">
                    <strong>Error:</strong> {attempt["error"]}
                  </div>
                  <div :if={attempt["error_body"]} class="mt-2">
                    <details class="collapse collapse-arrow bg-base-200">
                      <summary class="collapse-title text-xs py-1 min-h-0">Error Response</summary>
                      <div class="collapse-content">
                        <pre class="text-xs overflow-auto"><%= attempt["error_body"] %></pre>
                      </div>
                    </details>
                  </div>
                  <div
                    :if={attempt["streamed_to_client"]}
                    class="mt-2 flex items-center gap-2 text-xs text-warning"
                  >
                    <span class="badge badge-warning badge-sm">midstream fallback</span>
                    <span class="text-base-content/50">
                      {attempt["partial_content_length"]} chars already sent to client
                    </span>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Tools Invoked -->
      <div :if={length(@log.tools_invoked) > 0} class="card bg-base-100 shadow mb-6">
        <div class="card-body">
          <h2 class="card-title text-base">Tools Invoked</h2>
          <div class="flex flex-wrap gap-2">
            <span :for={tool <- @log.tools_invoked} class="badge badge-secondary badge-lg font-mono">
              {tool}
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

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_json(nil), do: ""

  defp format_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end

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

  defp overhead_percent(%{latency_ms: total} = log) when is_integer(total) and total > 0 do
    overhead = overhead_time(log)
    percent = Float.round(overhead / total * 100, 1)
    "#{percent}%"
  end

  defp overhead_percent(_), do: "-"
end
