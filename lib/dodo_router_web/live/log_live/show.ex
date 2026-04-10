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
    <div class="max-w-5xl mx-auto">
      <.header>
        Request Details
        <:subtitle>
          <code class="text-sm"><%= @log.request_id %></code>
        </:subtitle>
      </.header>

      <div class="mt-8 grid grid-cols-2 gap-8">
        <div class="space-y-6">
          <.card title="Overview">
            <dl class="space-y-2">
              <.dl_row label="Status">
                <.status_badge status={@log.status} />
              </.dl_row>
              <.dl_row label="Provider"><%= @log.final_provider %></.dl_row>
              <.dl_row label="Model"><%= @log.final_model %></.dl_row>
              <.dl_row label="Call Type">
                <.call_type_badge type={@log.call_type} />
              </.dl_row>
              <.dl_row label="Timestamp"><%= format_datetime(@log.inserted_at) %></.dl_row>
            </dl>
          </.card>

          <.card title="Performance">
            <dl class="space-y-2">
              <.dl_row label="Total Latency"><%= @log.latency_ms || "-" %> ms</.dl_row>
              <.dl_row label="Time to First Byte"><%= @log.ttfb_ms || "-" %> ms</.dl_row>
              <.dl_row label="Prompt Tokens"><%= @log.prompt_tokens || "-" %></.dl_row>
              <.dl_row label="Completion Tokens"><%= @log.completion_tokens || "-" %></.dl_row>
              <.dl_row label="Total Tokens"><%= @log.total_tokens || "-" %></.dl_row>
              <.dl_row label="Estimated Cost">
                <%= if @log.estimated_cost_usd, do: "$#{Decimal.round(@log.estimated_cost_usd, 6)}", else: "-" %>
              </.dl_row>
            </dl>
          </.card>

          <.card :if={length(@log.tools_invoked) > 0} title="Tools Invoked">
            <ul class="space-y-1">
              <li :for={tool <- @log.tools_invoked} class="font-mono text-sm bg-purple-50 px-2 py-1 rounded">
                <%= tool %>
              </li>
            </ul>
          </.card>
        </div>

        <div>
          <.card title="Routing Chain">
            <div class="space-y-3">
              <div :for={{attempt, idx} <- Enum.with_index(@log.attempted_steps)} class={"p-3 rounded-lg border #{attempt_class(attempt)}"}>
                <div class="flex items-center gap-2">
                  <span class="w-6 h-6 flex items-center justify-center bg-gray-200 rounded-full text-sm font-semibold">
                    <%= idx + 1 %>
                  </span>
                  <span class="font-medium"><%= attempt["provider"] %></span>
                  <span class="text-gray-500">/ <%= attempt["model"] %></span>
                </div>
                <div class="mt-2 text-sm text-gray-600">
                  <span>Status: <span class={"font-medium #{if attempt["status"] == "success", do: "text-green-600", else: "text-red-600"}"}><%= attempt["status"] %></span></span>
                  <span class="ml-4">Latency: <%= attempt["latency_ms"] %>ms</span>
                </div>
                <div :if={attempt["error"]} class="mt-1 text-sm text-red-600">
                  Error: <%= attempt["error"] %>
                </div>
              </div>
            </div>
          </.card>
        </div>
      </div>

      <div :if={@log.request_body || @log.response_body} class="mt-8 grid grid-cols-2 gap-8">
        <.card :if={@log.request_body} title="Request Body">
          <pre class="text-xs bg-gray-50 p-3 rounded overflow-auto max-h-96"><%= format_json(@log.request_body) %></pre>
        </.card>

        <.card :if={@log.response_body} title="Response Body">
          <pre class="text-xs bg-gray-50 p-3 rounded overflow-auto max-h-96"><%= format_json(@log.response_body) %></pre>
        </.card>
      </div>

      <.back navigate={~p"/logs"}>Back to logs</.back>
    </div>
    """
  end

  defp card(assigns) do
    ~H"""
    <div class="bg-white border rounded-lg p-4">
      <h3 class="font-semibold text-gray-900 mb-3"><%= @title %></h3>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  defp dl_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <dt class="text-gray-500"><%= @label %></dt>
      <dd class="font-medium"><%= render_slot(@inner_block) %></dd>
    </div>
    """
  end

  defp status_badge(assigns) do
    class =
      case assigns.status do
        "success" -> "bg-green-100 text-green-800"
        "fallback" -> "bg-yellow-100 text-yellow-800"
        "error" -> "bg-red-100 text-red-800"
        _ -> "bg-gray-100 text-gray-800"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}><%= @status %></span>
    """
  end

  defp call_type_badge(assigns) do
    {label, class} =
      case assigns.type do
        "tool_call" -> {"Tool Call", "bg-purple-100 text-purple-800"}
        "tool_enabled_completion" -> {"Tool Enabled", "bg-blue-100 text-blue-800"}
        _ -> {"Completion", "bg-gray-100 text-gray-800"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-medium #{@class}"}><%= @label %></span>
    """
  end

  defp attempt_class(%{"status" => "success"}), do: "bg-green-50 border-green-200"
  defp attempt_class(_), do: "bg-red-50 border-red-200"

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_json(nil), do: ""

  defp format_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> str
    end
  end
end
