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

    {req_messages, req_params} = parse_request_body(log.request_body)
    resp_message = parse_response_body(log.response_body)
    req_headers = parse_headers(log.request_headers)
    resp_headers = parse_headers(log.response_headers)

    socket =
      socket
      |> assign(:page_title, "Request #{String.slice(log.request_id, 0, 8)}...")
      |> assign(:log, log)
      |> assign(:req_messages, req_messages)
      |> assign(:req_params, req_params)
      |> assign(:resp_message, resp_message)
      |> assign(:req_headers, req_headers)
      |> assign(:resp_headers, resp_headers)
      |> assign(:show_raw_request, false)
      |> assign(:show_raw_response, false)
      |> assign(:show_req_headers, false)
      |> assign(:show_resp_headers, false)
      |> assign(:expanded_messages, MapSet.new())
      |> assign(:truncation_flags, log.truncation_flags || [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :return_to, params["return_to"])}
  end

  @impl true
  def handle_event("toggle_raw_request", _params, socket) do
    {:noreply, update(socket, :show_raw_request, &(!&1))}
  end

  def handle_event("toggle_raw_response", _params, socket) do
    {:noreply, update(socket, :show_raw_response, &(!&1))}
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

      <%= if length(@truncation_flags) > 0 do %>
        <div class="alert alert-warning mb-6">
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
      
    <!-- Overview Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-3 mb-6">
        <div class="stat-card">
          <div class="stat-label text-xs">Status</div>
          <div class="stat-value text-lg"><.status_badge status={@log.status} /></div>
        </div>

        <div class="stat-card">
          <div class="stat-label text-xs">Provider</div>
          <div class="stat-value text-lg">{@log.final_provider}</div>
        </div>

        <div class="stat-card">
          <div class="stat-label text-xs">Model</div>
          <div class="stat-value text-sm font-mono">{@log.final_model}</div>
        </div>

        <div class="stat-card">
          <div class="stat-label text-xs">Latency</div>
          <div class="stat-value text-lg">{@log.latency_ms || "-"}ms</div>
        </div>

        <div class="stat-card">
          <div class="stat-label text-xs">Tokens</div>
          <div class="stat-value text-lg">{@log.total_tokens || "-"}</div>
        </div>

        <div class="stat-card">
          <div class="stat-label text-xs">Cost</div>
          <div class="stat-value text-lg">
            {if @log.estimated_cost_usd,
              do: "$#{Decimal.round(@log.estimated_cost_usd, 4)}",
              else: "-"}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
        <!-- Performance Card -->
        <div class="card-bordered">
          <h2 class="section-title mb-3">Performance</h2>
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
        
    <!-- Routing Chain Card -->
        <div class="card-bordered">
          <h2 class="section-title mb-3">Routing Chain</h2>
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
                  :if={attempt["forwarded_headers"] && map_size(attempt["forwarded_headers"]) > 0}
                  class="mt-2 text-xs"
                >
                  <div class="text-base-content/60 mb-1">Headers modified:</div>
                  <div class="space-y-0.5 font-mono">
                    <%= for {header, note} <- attempt["forwarded_headers"] do %>
                      <div class="flex gap-2 items-start">
                        <span class="badge badge-xs badge-ghost">→</span>
                        <span class="font-medium">{header}:</span>
                        <span class="text-base-content/70">{note}</span>
                      </div>
                    <% end %>
                  </div>
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
      
    <!-- Tools Invoked -->
      <div :if={length(@log.tools_invoked) > 0} class="card-bordered mb-6">
        <h2 class="section-title mb-3">Tools Invoked</h2>
        <div class="flex flex-wrap gap-2">
          <span :for={tool <- @log.tools_invoked} class="badge badge-secondary badge-lg font-mono">
            {tool}
          </span>
        </div>
      </div>
      
    <!-- Request & Response -->
      <div :if={@log.request_body || @log.response_body} class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <!-- Request -->
        <div :if={@log.request_body} class="card-bordered">
          <div class="flex items-center justify-between mb-3">
            <h2 class="section-title mb-0">Request</h2>
            <div class="flex gap-2">
              <button :if={@req_headers} phx-click="toggle_req_headers" class="btn btn-ghost btn-xs">
                Headers
              </button>
              <button
                phx-click="toggle_raw_request"
                class="btn btn-ghost btn-xs"
              >
                {if @show_raw_request, do: "Compact", else: "Raw JSON"}
              </button>
            </div>
          </div>

          <div
            :if={@show_req_headers && @req_headers}
            class="mb-3 p-2 bg-base-200 rounded-lg text-xs font-mono space-y-1"
          >
            <%= for {key, value} <- @req_headers do %>
              <div class="flex gap-2">
                <span class="text-base-content/60 shrink-0">{key}:</span>
                <span class="break-all">{value}</span>
              </div>
            <% end %>
          </div>

          <%= if @show_raw_request do %>
            <div class="mockup-code text-xs max-h-64 overflow-auto">
              <pre><code><%= format_json(@log.request_body) %></code></pre>
            </div>
          <% else %>
            <%= if length(@req_messages) > 0 do %>
              <div class="space-y-2">
                <%= for {msg, idx} <- Enum.with_index(@req_messages) do %>
                  <.compact_message
                    message={msg}
                    index={idx}
                    expanded={MapSet.member?(@expanded_messages, idx)}
                  />
                <% end %>
              </div>
            <% else %>
              <div class="mockup-code text-xs max-h-64 overflow-auto">
                <pre><code><%= format_json(@log.request_body) %></code></pre>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Response -->
        <div :if={@log.response_body} class="card-bordered">
          <div class="flex items-center justify-between mb-3">
            <h2 class="section-title mb-0">Response</h2>
            <div class="flex gap-2">
              <button
                :if={@resp_headers}
                phx-click="toggle_resp_headers"
                class="btn btn-ghost btn-xs"
              >
                Headers
              </button>
              <button
                phx-click="toggle_raw_response"
                class="btn btn-ghost btn-xs"
              >
                {if @show_raw_response, do: "Compact", else: "Raw JSON"}
              </button>
            </div>
          </div>

          <div
            :if={@show_resp_headers && @resp_headers}
            class="mb-3 p-2 bg-base-200 rounded-lg text-xs font-mono space-y-1"
          >
            <%= for {key, value} <- @resp_headers do %>
              <div class="flex gap-2">
                <span class="text-base-content/60 shrink-0">{key}:</span>
                <span class="break-all">{value}</span>
              </div>
            <% end %>
          </div>

          <%= if @show_raw_response do %>
            <div class="mockup-code text-xs max-h-64 overflow-auto">
              <pre><code><%= format_json(@log.response_body) %></code></pre>
            </div>
          <% else %>
            <%= if @resp_message do %>
              <.compact_message
                message={@resp_message}
                index="resp"
                expanded={MapSet.member?(@expanded_messages, "resp")}
              />
            <% else %>
              <div class="mockup-code text-xs max-h-64 overflow-auto">
                <pre><code><%= format_json(@log.response_body) %></code></pre>
              </div>
            <% end %>
          <% end %>
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

  defp parse_request_body(nil), do: {[], %{}}

  defp parse_request_body(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, %{"messages" => messages} = decoded} when is_list(messages) ->
        {Enum.map(messages, &normalize_message/1), Map.drop(decoded, ["messages"])}

      _ ->
        {[], %{}}
    end
  end

  defp parse_response_body(nil), do: nil

  defp parse_response_body(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, %{"choices" => [%{"message" => msg} | _]}} ->
        normalize_message(msg)

      {:ok, %{"choices" => [%{"delta" => delta} | _]}} ->
        normalize_message(delta)

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

  defp normalize_message(%{"role" => role, "content" => content} = msg) do
    %{
      role: role,
      content: normalize_content(content),
      tool_calls: msg["tool_calls"],
      tool_call_id: msg["tool_call_id"],
      name: msg["name"]
    }
  end

  defp normalize_message(%{"content" => content} = msg) do
    %{
      role: msg["role"] || "assistant",
      content: normalize_content(content),
      tool_calls: msg["tool_calls"],
      tool_call_id: msg["tool_call_id"],
      name: msg["name"]
    }
  end

  defp normalize_message(msg),
    do: %{role: "unknown", content: inspect(msg), tool_calls: nil, tool_call_id: nil, name: nil}

  defp normalize_content(nil), do: ""
  defp normalize_content(str) when is_binary(str), do: str

  defp normalize_content(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n\n")
  end

  defp normalize_content(other), do: inspect(other)

  attr :message, :map, required: true
  attr :index, :any, required: true
  attr :expanded, :boolean, default: false

  defp compact_message(assigns) do
    role = assigns.message.role

    {badge_class, label} =
      case role do
        "system" -> {"badge-ghost", "system"}
        "user" -> {"badge-primary", "user"}
        "assistant" -> {"badge-secondary", "assistant"}
        "tool" -> {"badge-warning", "tool"}
        _ -> {"badge-ghost", role || "unknown"}
      end

    content = assigns.message.content
    is_truncated = String.length(content) > 120

    assigns =
      assigns
      |> assign(:badge_class, badge_class)
      |> assign(:label, label)
      |> assign(:display_content, if(assigns.expanded, do: content, else: truncate(content, 120)))
      |> assign(:is_truncated, is_truncated)

    ~H"""
    <div
      class="group cursor-pointer rounded-lg hover:bg-base-200/50 transition-colors p-1 -mx-1"
      phx-click="toggle_message"
      phx-value-index={@index}
    >
      <div class="flex items-start gap-2">
        <span class={["badge badge-xs font-mono capitalize flex-shrink-0 mt-0.5", @badge_class]}>
          {@label}
        </span>
        <div class="min-w-0 flex-1">
          <p class={[
            "text-sm text-base-content/80 leading-snug whitespace-pre-wrap",
            !@expanded && "line-clamp-2"
          ]}>
            {@display_content}
          </p>
          <%= if @is_truncated do %>
            <span class="text-[10px] text-primary mt-0.5 block">
              {if @expanded, do: "Show less", else: "Click to expand"}
            </span>
          <% end %>
        </div>
      </div>
      <%= if @message.tool_calls && length(@message.tool_calls) > 0 do %>
        <div class="mt-1.5 ml-10 flex flex-wrap gap-1">
          <%= for tool <- @message.tool_calls do %>
            <.tool_badge tool={tool} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :tool, :map, required: true

  defp tool_badge(assigns) do
    name = assigns.tool["function"]["name"] || assigns.tool["name"] || "unknown"
    args = assigns.tool["function"]["arguments"] || assigns.tool["arguments"] || "{}"

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:args_preview, truncate(args, 60))

    ~H"""
    <div class="inline-flex items-center gap-1 text-xs font-mono bg-primary/10 text-primary rounded px-1.5 py-0.5">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-3 w-3"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
        />
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
        />
      </svg>
      <span>{@name}</span>
      <span class="text-primary/60">({@args_preview})</span>
    </div>
    """
  end

  defp truncate(nil, _len), do: ""

  defp truncate(str, len) when is_binary(str) do
    if String.length(str) > len do
      String.slice(str, 0, len) <> "..."
    else
      str
    end
  end

  defp truncate(other, _len), do: inspect(other)

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
