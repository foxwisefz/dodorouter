defmodule DodoRouterWeb.PromptComponents do
  @moduledoc """
  Components for rendering LLM conversations on the private log detail page.
  """
  use Phoenix.Component

  import DodoRouterWeb.CoreComponents

  alias DodoRouterWeb.MarkdownRenderer

  @doc """
  A chat-bubble style conversation view.

  ## Attributes

    * `:messages` — list of normalized request messages (role/content/tool_calls)
    * `:response` — the assistant response message (or nil)
    * `:model` — display string e.g. "gpt-4"
    * `:provider` — display string e.g. "openai"
  """
  attr :messages, :list, required: true
  attr :response, :any, default: nil
  attr :model, :string, default: nil
  attr :provider, :string, default: nil
  attr :tools, :list, default: []

  def conversation(assigns) do
    {system_messages, other_messages} =
      Enum.split_with(assigns.messages, fn msg -> msg.role == "system" end)

    # Build lookup of tool_call_id -> result content from tool messages
    tool_results =
      other_messages
      |> Enum.filter(fn msg -> msg.role == "tool" end)
      |> Enum.reduce(%{}, fn msg, acc ->
        id = msg.tool_call_id || msg.name || "unknown"
        Map.put(acc, id, msg.content)
      end)

    # Filter out tool result messages from display - they'll be shown inline
    display_messages = Enum.reject(other_messages, fn msg -> msg.role == "tool" end)

    assigns =
      assigns
      |> assign(:system_messages, system_messages)
      |> assign(:display_messages, display_messages)
      |> assign(:tool_results, tool_results)

    ~H"""
    <div class="space-y-4">
      <%= if @model || @provider do %>
        <div class="sticky top-0 z-10 -mx-4 px-4 py-2 bg-base-100/80 backdrop-blur border-b border-base-300/50 flex items-center gap-2 text-xs">
          <%= if @provider do %>
            <span class="font-mono text-base-content/50 lowercase">{@provider}</span>
          <% end %>
          <%= if @model do %>
            <span class="font-mono text-base-content font-semibold">{@model}</span>
          <% end %>
        </div>
      <% end %>

      <div class="space-y-3">
        <.collapsed_message_list messages={@system_messages} response={false} tool_results={%{}} />

        <%= if length(@tools) > 0 do %>
          <.available_tools tools={@tools} />
        <% end %>

        <.collapsed_message_list
          messages={@display_messages}
          response={@response}
          tool_results={@tool_results}
        />
      </div>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :response, :any, default: nil
  attr :tool_results, :map, default: %{}

  defp collapsed_message_list(assigns) do
    segments = build_segments(assigns.messages, assigns.response)
    assigns = assign(assigns, :segments, segments)

    ~H"""
    <%= for {seg, idx} <- Enum.with_index(@segments) do %>
      <div :if={seg.collapsed} class="flex items-center gap-2 px-4 py-2">
        <div class="flex-1 border-t border-dashed border-base-300/40"></div>
        <span class="text-xs text-base-content/40 font-medium">
          {seg.count} repeated message{seg.count > 1 && "s"} collapsed
        </span>
        <div class="flex-1 border-t border-dashed border-base-300/40"></div>
      </div>
      <.message_bubble
        message={seg.message}
        index={seg.index}
        response={seg.response}
        next_message={message_at(@segments, idx + 1)}
        prev_message={message_at(@segments, idx - 1)}
        tool_results={@tool_results}
      />
    <% end %>
    """
  end

  def message_at(segments, index) when index >= 0 and index < length(segments) do
    Enum.at(segments, index).message
  end

  def message_at(_, _), do: nil

  defp build_segments(messages, response) do
    items =
      Enum.with_index(messages)
      |> Enum.map(fn {msg, idx} -> %{message: msg, index: idx, response: false} end)

    items =
      if response,
        do: items ++ [%{message: response, index: "response", response: true}],
        else: items

    items
    |> Enum.reduce([], fn item, acc ->
      case acc do
        [%{collapsed: true, message: prev_msg, count: count} = prev_item | rest] ->
          if same_message?(prev_item, item) do
            [
              %{
                collapsed: true,
                message: prev_msg,
                index: item.index,
                response: item.response,
                count: count + 1
              }
              | rest
            ]
          else
            [Map.put(item, :collapsed, false) | acc]
          end

        [%{collapsed: false, message: prev_msg} = prev_item | _] ->
          if same_message?(prev_item, item) do
            [
              %{
                collapsed: true,
                message: prev_msg,
                index: item.index,
                response: item.response,
                count: 2
              }
              | tl(acc)
            ]
          else
            [Map.put(item, :collapsed, false) | acc]
          end

        [] ->
          [Map.put(item, :collapsed, false)]
      end
    end)
    |> Enum.reverse()
  end

  defp same_message?(%{message: a, response: ra}, %{message: b, response: rb}) do
    ra == rb and a.role == b.role and a.content == b.content and
      a.tool_calls == b.tool_calls and a.name == b.name
  end

  attr :message, :map, required: true
  attr :index, :any, required: true
  attr :response, :boolean, default: false
  attr :next_message, :map, default: nil
  attr :prev_message, :map, default: nil
  attr :tool_results, :map, default: %{}

  defp message_bubble(assigns) do
    role = assigns.message.role
    {bubble_class, label_class, label} = role_styles(role, assigns.response)

    assigns =
      assigns
      |> assign(:bubble_class, bubble_class)
      |> assign(:label_class, label_class)
      |> assign(:label, label)
      |> assign(:role, role)

    ~H"""
    <div class={"group flex flex-col gap-1.5 #{align_class(@role)}"}>
      <div class="flex items-center gap-2 px-1">
        <span class={"text-[10px] uppercase tracking-wider font-semibold #{@label_class}"}>
          {@label}
        </span>
        <%= if is_binary(@message.content) && @message.content != "" do %>
          <button
            type="button"
            id={"copy-#{@index}"}
            phx-hook="CopyButton"
            data-copy={@message.content}
            class="text-[10px] text-base-content/30 hover:text-primary opacity-0 group-hover:opacity-100 transition"
            title="Copy raw message"
          >
            copy raw
          </button>
        <% end %>
      </div>

      <div class={"max-w-[85%] rounded-2xl px-4 py-3 shadow-sm #{@bubble_class}"}>
        <div class="max-w-none">
          <MarkdownRenderer.render content={@message.content} />
        </div>

        <%= if @message.tool_calls && @message.tool_calls != [] do %>
          <div class="mt-3 space-y-2">
            <%= for tc <- @message.tool_calls do %>
              <.tool_call_card call={tc} tool_results={@tool_results} />
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp role_styles("user", _), do: {"bg-primary text-primary-content", "text-primary/70", "you"}

  defp role_styles("assistant", true),
    do: {"bg-base-200 border border-base-300/40", "text-secondary", "assistant"}

  defp role_styles("assistant", false),
    do: {"bg-base-200/60 border border-base-300/30", "text-base-content/50", "assistant"}

  defp role_styles("system", _),
    do: {"bg-base-300/40 text-base-content/70", "text-base-content/40", "system"}

  defp role_styles("tool", _),
    do: {"bg-warning/10 border border-warning/30", "text-warning", "tool result"}

  defp role_styles(other, _), do: {"bg-base-200", "text-base-content/40", other || "msg"}

  defp align_class("user"), do: "items-end"
  defp align_class(_), do: "items-start"

  attr :call, :map, required: true
  attr :tool_results, :map, default: %{}

  defp tool_call_card(assigns) do
    name = get_in(assigns.call, ["function", "name"]) || assigns.call["name"] || "tool"
    call_id = assigns.call["id"] || ""

    raw_args =
      get_in(assigns.call, ["function", "arguments"]) || assigns.call["arguments"] || "{}"

    args =
      case Jason.decode(to_string(raw_args)) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    result = Map.get(assigns.tool_results, call_id)

    assigns =
      assign(assigns,
        name: name,
        args: args,
        raw_args: raw_args,
        call_id: call_id,
        has_result: not is_nil(result),
        result: result
      )

    ~H"""
    <div class="rounded border border-base-300/40 bg-base-100/40 overflow-hidden">
      <.heuristic_tool_call name={@name} args={@args} raw_args={@raw_args} />
      <%= if @has_result do %>
        <div class="border-t border-base-300/30 bg-base-200/30">
          <div class="flex items-center gap-1.5 px-3 py-1 text-[10px] text-base-content/40">
            <.icon name="hero-arrow-down" class="w-3 h-3" />
            <span>result</span>
          </div>
          <pre class="px-3 pb-2 text-[11px] overflow-x-auto whitespace-pre-wrap font-mono"><%= @result %></pre>
        </div>
      <% end %>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :args, :map, required: true
  attr :raw_args, :string, default: "{}"

  defp heuristic_tool_call(assigns) do
    cond do
      assigns.args["command"] -> render_command_tool(assigns)
      assigns.args["file_path"] || assigns.args["path"] -> render_file_tool(assigns)
      assigns.args["riskLevel"] -> render_risk_tool(assigns)
      assigns.args["questions"] || assigns.args["options"] -> render_question_tool(assigns)
      true -> render_generic_tool(assigns)
    end
  end

  defp render_command_tool(assigns) do
    command = assigns.args["command"] || ""
    description = assigns.args["description"] || ""

    assigns = assign(assigns, command: command, description: description)

    ~H"""
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
      <.icon name="hero-command-line" class="w-4 h-4 text-secondary" />
      <span class="font-semibold">{@name}</span>
    </div>
    <div class="px-3 py-2 space-y-1.5">
      <%= if @description && String.length(@description) > 0 do %>
        <div class="text-sm text-base-content/50 italic">{@description}</div>
      <% end %>
      <div class="font-mono text-[11px] bg-base-300/20 rounded px-2 py-1.5 border border-base-300/30">
        <code>{@command}</code>
      </div>
      <.raw_json_toggle raw_args={@raw_args} />
    </div>
    """
  end

  defp render_file_tool(assigns) do
    path = assigns.args["file_path"] || assigns.args["path"] || ""

    assigns = assign(assigns, path: path)

    ~H"""
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
      <.icon name="hero-document-text" class="w-4 h-4 text-secondary" />
      <span class="font-semibold">{@name}</span>
    </div>
    <div class="px-3 py-2 space-y-1.5">
      <div class="font-mono text-[11px] bg-base-300/20 rounded px-2 py-1.5 border border-base-300/30 truncate">
        <code>{@path}</code>
      </div>
      <.raw_json_toggle raw_args={@raw_args} />
    </div>
    """
  end

  defp render_risk_tool(assigns) do
    command = assigns.args["command"] || ""
    risk_level = assigns.args["riskLevel"] || "unknown"
    timeout = assigns.args["timeout"]
    description = assigns.args["description"] || ""

    risk_class =
      case risk_level do
        "low" -> "badge-success"
        "medium" -> "badge-warning"
        "high" -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns =
      assign(assigns,
        command: command,
        risk_level: risk_level,
        timeout: timeout,
        description: description,
        risk_class: risk_class
      )

    ~H"""
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
      <.icon name="hero-play" class="w-4 h-4 text-secondary" />
      <span class="font-semibold">{@name}</span>
      <span class={["badge badge-xs", @risk_class]}>{@risk_level}</span>
    </div>
    <div class="px-3 py-2 space-y-1.5">
      <%= if @description && String.length(@description) > 0 do %>
        <div class="text-sm text-base-content/50 italic">{@description}</div>
      <% end %>
      <div class="font-mono text-[11px] bg-base-300/20 rounded px-2 py-1.5 border border-base-300/30">
        <code>{@command}</code>
      </div>
      <%= if @timeout do %>
        <div class="text-xs text-base-content/50">Timeout: {@timeout}s</div>
      <% end %>
      <.raw_json_toggle raw_args={@raw_args} />
    </div>
    """
  end

  defp render_question_tool(assigns) do
    questions = assigns.args["questions"] || []
    options = assigns.args["options"] || []

    assigns = assign(assigns, questions: questions, options: options)

    ~H"""
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
      <.icon name="hero-question-mark-circle" class="w-4 h-4 text-secondary" />
      <span class="font-semibold">{@name}</span>
    </div>
    <div class="px-3 py-2 space-y-2">
      <%= for q <- @questions do %>
        <div class="text-[11px] font-medium">{question_text(q)}</div>
      <% end %>
      <%= if length(@options) > 0 do %>
        <div class="flex flex-wrap gap-1">
          <%= for opt <- @options do %>
            <span class="px-2 py-0.5 rounded bg-base-200 text-[10px]">{option_label(opt)}</span>
          <% end %>
        </div>
      <% end %>
      <.raw_json_toggle raw_args={@raw_args} />
    </div>
    """
  end

  defp question_text(q) when is_map(q), do: q["question"] || ""
  defp question_text(q) when is_binary(q), do: q
  defp question_text(_), do: ""

  defp option_label(opt) when is_map(opt), do: opt["label"] || ""
  defp option_label(opt) when is_binary(opt), do: opt
  defp option_label(_), do: ""

  defp render_generic_tool(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
      <.icon name="hero-wrench" class="w-4 h-4 text-secondary" />
      <span class="font-semibold">{@name}</span>
    </div>
    <div class="px-3 py-2">
      <pre class="text-[11px] overflow-x-auto"><code phx-no-curly-interpolation><%= Jason.encode!(@args, pretty: true) %></code></pre>
    </div>
    """
  end

  attr :raw_args, :string, required: true

  defp raw_json_toggle(assigns) do
    ~H"""
    <details class="text-[10px]">
      <summary class="text-base-content/40 hover:text-base-content cursor-pointer select-none">
        Show raw JSON
      </summary>
      <pre class="mt-1 p-1.5 bg-base-300/20 rounded overflow-x-auto"><code phx-no-curly-interpolation><%= @raw_args %></code></pre>
    </details>
    """
  end

  @doc """
  Render a session tree built by `DodoRouter.Logs.SessionTree.build/1`.

  Clicking a node patches `?log=<log_id>` so the parent LiveView can show
  that branch's chat in a side pane.
  """
  attr :tree, :map, required: true
  attr :selected_log_id, :string, default: nil

  def session_tree(assigns) do
    ~H"""
    <div class="font-mono text-xs">
      <.tree_node node={@tree} selected_log_id={@selected_log_id} is_root={true} />
    </div>
    """
  end

  attr :node, :map, required: true
  attr :selected_log_id, :string, default: nil
  attr :is_root, :boolean, default: false

  defp tree_node(assigns) do
    ~H"""
    <div class={["pl-3", !@is_root && "border-l border-base-300/40 ml-2"]}>
      <%= if @node.message do %>
        <.tree_turn message={@node.message} />
      <% end %>

      <%= for log <- @node.logs do %>
        <.tree_leaf log={log} selected={@selected_log_id == log.id} />
      <% end %>

      <%= for child <- @node.children do %>
        <.tree_node node={child} selected_log_id={@selected_log_id} />
      <% end %>
    </div>
    """
  end

  attr :message, :map, required: true

  defp tree_turn(assigns) do
    snippet =
      assigns.message.content
      |> to_string()
      |> String.slice(0, 60)
      |> String.replace("\n", " ")

    assigns = assign(assigns, snippet: snippet)

    ~H"""
    <div class="py-1 flex items-baseline gap-2">
      <span class={"text-[10px] uppercase #{role_color(@message.role)}"}>{@message.role}</span>
      <span class="truncate text-base-content/70">{@snippet}</span>
    </div>
    """
  end

  attr :log, :map, required: true
  attr :selected, :boolean, default: false

  defp tree_leaf(assigns) do
    ~H"""
    <.link
      patch={"?log=#{@log.id}"}
      class={[
        "block py-1 px-2 -ml-2 rounded text-[11px]",
        @selected && "bg-primary/10 text-primary border-l-2 border-primary",
        !@selected && "hover:bg-base-200 text-base-content/60"
      ]}
    >
      📍 log {String.slice(@log.id, 0, 8)}
    </.link>
    """
  end

  defp role_color("user"), do: "text-primary"
  defp role_color("assistant"), do: "text-secondary"
  defp role_color("system"), do: "text-base-content/40"
  defp role_color("tool"), do: "text-warning"
  defp role_color(_), do: "text-base-content/40"

  attr :tools, :list, required: true

  def available_tools(assigns) do
    ~H"""
    <div class="px-4 py-2 bg-base-200/20 border-y border-base-300/20">
      <div class="flex items-center gap-2 mb-1.5">
        <span class="text-[10px] uppercase tracking-wider text-base-content/40 font-semibold">
          Tools
        </span>
        <span class="text-[10px] text-base-content/30">{length(@tools)} available</span>
      </div>
      <div class="flex flex-wrap gap-1.5">
        <%= for tool <- @tools do %>
          <button
            type="button"
            phx-click="show_tool"
            phx-value-name={tool.name}
            class="inline-flex items-center gap-1 px-2 py-1 rounded bg-base-100/80 border border-base-300/30 text-[11px] hover:bg-base-200 hover:border-base-300/50 transition select-none cursor-pointer"
          >
            <.icon name={tool_icon(tool.name)} class="w-3 h-3 text-base-content/50" />
            <span class="font-medium font-mono text-base-content/70">{tool.name}</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def tool_icon(name) do
    icons = [
      "hero-wrench",
      "hero-bolt",
      "hero-cog-6-tooth",
      "hero-magnifying-glass",
      "hero-calculator",
      "hero-globe-alt",
      "hero-cloud",
      "hero-database",
      "hero-code-bracket",
      "hero-document-text",
      "hero-chart-bar",
      "hero-envelope",
      "hero-map-pin",
      "hero-camera",
      "hero-shield-check"
    ]

    index =
      name
      |> to_string()
      |> String.to_charlist()
      |> Enum.sum()
      |> rem(length(icons))

    Enum.at(icons, index)
  end
end
