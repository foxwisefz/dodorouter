defmodule DodoRouterWeb.LogLive.Show do
  use DodoRouterWeb, :live_view

  alias DodoRouter.Logs
  alias DodoRouter.Logs.MessageNormalizer

  import DodoRouterWeb.PromptComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Try by primary key first, then by request_id (for live stream links)
    log =
      case Logs.get_log(socket.assigns.current_user, id) do
        nil -> Logs.get_log_by_request_id!(socket.assigns.current_user, id)
        log -> log
      end

    {req_messages, req_params} = MessageNormalizer.parse_request_body(log.request_body)
    resp_message = MessageNormalizer.parse_response_body(log.response_body)
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
      |> assign(:show_performance, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_raw_request", _params, socket) do
    {:noreply, update(socket, :show_raw_request, &(!&1))}
  end

  def handle_event("toggle_raw_response", _params, socket) do
    {:noreply, update(socket, :show_raw_response, &(!&1))}
  end

  def handle_event("toggle_performance", _params, socket) do
    {:noreply, update(socket, :show_performance, &(!&1))}
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
            </div>
          </div>

          <!-- Model -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Model
            </div>
            <div class="text-sm font-mono">{@log.final_model}</div>
            <div class="text-xs text-base-content/60">{@log.final_provider}</div>
          </div>

          <!-- Usage -->
          <div>
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold mb-1">
              Usage
            </div>
            <div class="space-y-1 text-xs">
              <div class="flex justify-between">
                <span class="text-base-content/60">Tokens</span>
                <span class="font-mono">{@log.total_tokens || "-"}</span>
              </div>
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
                  <span class="text-base-content/40 font-mono ml-auto">{attempt["latency_ms"]}ms</span>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Right content -->
        <div class="flex-1 overflow-y-auto">
          <!-- Truncation warning -->
          <%= if length(@truncation_flags) > 0 do %>
            <div class="alert alert-warning m-4 mb-0">
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

          <!-- Conversation -->
          <div class="p-4">
            <.conversation
              messages={@req_messages}
              response={@resp_message}
              model={@log.final_model}
              provider={@log.final_provider}
            />
          </div>

          <!-- Bottom drawers -->
          <div class="border-t border-base-300/30 px-4 pb-4 space-y-3">
            <!-- Raw Request -->
            <div>
              <button
                type="button"
                phx-click="toggle_raw_request"
                class="w-full flex items-center justify-between py-2 text-xs font-medium text-base-content/60 hover:text-base-content transition"
              >
                <span class="flex items-center gap-2">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"
                    />
                  </svg>
                  Raw Request
                </span>
                <svg
                  class={["w-3 h-3 transition-transform", @show_raw_request && "rotate-180"]}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </button>

              <%= if @show_raw_request do %>
                <div class="mt-2 space-y-2">
                  <%= if @req_headers do %>
                    <button
                      type="button"
                      phx-click="toggle_req_headers"
                      class="text-xs text-primary hover:underline"
                    >
                      {if @show_req_headers, do: "Hide headers", else: "Show headers"}
                    </button>
                    <%= if @show_req_headers do %>
                      <div class="p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                        <%= for {key, value} <- @req_headers do %>
                          <div class="flex gap-2">
                            <span class="text-base-content/60 shrink-0">{key}:</span>
                            <span class="break-all">{value}</span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  <% end %>
                  <div class="mockup-code text-xs max-h-96 overflow-auto">
                    <pre><code><%= format_json(@log.request_body) %></code></pre>
                  </div>
                </div>
              <% end %>
            </div>

            <!-- Raw Response -->
            <div>
              <button
                type="button"
                phx-click="toggle_raw_response"
                class="w-full flex items-center justify-between py-2 text-xs font-medium text-base-content/60 hover:text-base-content transition"
              >
                <span class="flex items-center gap-2">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                    />
                  </svg>
                  Raw Response
                </span>
                <svg
                  class={["w-3 h-3 transition-transform", @show_raw_response && "rotate-180"]}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </button>

              <%= if @show_raw_response do %>
                <div class="mt-2 space-y-2">
                  <%= if @resp_headers do %>
                    <button
                      type="button"
                      phx-click="toggle_resp_headers"
                      class="text-xs text-primary hover:underline"
                    >
                      {if @show_resp_headers, do: "Hide headers", else: "Show headers"}
                    </button>
                    <%= if @show_resp_headers do %>
                      <div class="p-2 bg-base-200 rounded text-xs font-mono space-y-1">
                        <%= for {key, value} <- @resp_headers do %>
                          <div class="flex gap-2">
                            <span class="text-base-content/60 shrink-0">{key}:</span>
                            <span class="break-all">{value}</span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  <% end %>
                  <div class="mockup-code text-xs max-h-96 overflow-auto">
                    <pre><code><%= format_json(@log.response_body) %></code></pre>
                  </div>
                </div>
              <% end %>
            </div>

            <!-- Performance -->
            <div>
              <button
                type="button"
                phx-click="toggle_performance"
                class="w-full flex items-center justify-between py-2 text-xs font-medium text-base-content/60 hover:text-base-content transition"
              >
                <span class="flex items-center gap-2">
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 10V3L4 14h7v7l9-11h-7z"
                    />
                  </svg>
                  Performance Details
                </span>
                <svg
                  class={["w-3 h-3 transition-transform", @show_performance && "rotate-180"]}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </button>

              <%= if @show_performance do %>
                <div class="mt-2 space-y-4">
                  <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                    <div class="card-bordered">
                      <h3 class="section-title mb-2">Timing</h3>
                      <table class="table table-sm">
                        <tbody>
                          <tr>
                            <td class="text-base-content/60">Call Type</td>
                            <td class="text-right"><.call_type_badge type={@log.call_type} /></td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">Total</td>
                            <td class="text-right font-mono">{@log.latency_ms || "-"} ms</td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">Provider</td>
                            <td class="text-right font-mono">{provider_time(@log)} ms</td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">Overhead</td>
                            <td class="text-right">
                              <span class="font-mono">{overhead_time(@log)} ms</span>
                              <span class="text-success text-xs">({overhead_percent(@log)})</span>
                            </td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">TTFB</td>
                            <td class="text-right font-mono">{@log.ttfb_ms || "-"} ms</td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">Upload</td>
                            <td class="text-right font-mono">{@log.upload_ms || "-"} ms</td>
                          </tr>
                          <tr>
                            <td class="text-base-content/60">Wait</td>
                            <td class="text-right font-mono">{wait_time(@log)} ms</td>
                          </tr>
                          <tr :if={@log.provider_processing_ms}>
                            <td class="text-base-content/60">Provider Proc</td>
                            <td class="text-right font-mono">{@log.provider_processing_ms} ms</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>

                    <div class="card-bordered">
                      <h3 class="section-title mb-2">Routing Chain</h3>
                      <div class="space-y-2">
                        <%= for {attempt, _idx} <- Enum.with_index(@log.attempted_steps) do %>
                          <div class={[
                            "p-2 rounded border-l-2 text-xs",
                            attempt["status"] == "success" && "bg-success/5 border-success",
                            attempt["status"] != "success" && "bg-error/5 border-error"
                          ]}>
                            <div class="flex items-center justify-between">
                              <span class="font-medium">{attempt["provider"]} / {attempt["model"]}</span>
                              <span class="font-mono">{attempt["latency_ms"]}ms</span>
                            </div>
                            <%= if attempt["error"] do %>
                              <div class="text-error mt-1">{attempt["error"]}</div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%= if length(@log.tools_invoked) > 0 do %>
                    <div class="card-bordered">
                      <h3 class="section-title mb-2">Tools</h3>
                      <div class="flex flex-wrap gap-2">
                        <span
                          :for={tool <- @log.tools_invoked}
                          class="badge badge-secondary badge-sm font-mono"
                        >
                          {tool}
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
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

  defp wait_time(%{ttfb_ms: ttfb, upload_ms: upload})
       when is_integer(ttfb) and is_integer(upload) do
    ttfb - upload
  end

  defp wait_time(_), do: "-"

  defp format_bytes(nil), do: "-"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 2)} MB"
end
