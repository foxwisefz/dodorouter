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

    assigns =
      assigns
      |> assign(:system_messages, system_messages)
      |> assign(:other_messages, other_messages)

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
        <.collapsed_message_list messages={@system_messages} response={false} />

        <%= if length(@tools) > 0 do %>
          <.available_tools tools={@tools} />
        <% end %>

        <.collapsed_message_list messages={@other_messages} response={@response} />
      </div>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :response, :any, default: nil

  defp collapsed_message_list(assigns) do
    segments = build_segments(assigns.messages, assigns.response)
    assigns = assign(assigns, :segments, segments)

    ~H"""
    <%= for seg <- @segments do %>
      <div :if={seg.collapsed} class="flex items-center gap-2 px-4 py-2">
        <div class="flex-1 border-t border-dashed border-base-300/40"></div>
        <span class="text-xs text-base-content/40 font-medium">
          {seg.count} repeated message{seg.count > 1 && "s"} collapsed
        </span>
        <div class="flex-1 border-t border-dashed border-base-300/40"></div>
      </div>
      <.message_bubble message={seg.message} index={seg.index} response={seg.response} />
    <% end %>
    """
  end

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
              <.tool_call_card call={tc} />
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

  defp tool_call_card(assigns) do
    name = get_in(assigns.call, ["function", "name"]) || assigns.call["name"] || "tool"

    raw_args =
      get_in(assigns.call, ["function", "arguments"]) || assigns.call["arguments"] || "{}"

    args_pretty =
      case Jason.decode(to_string(raw_args)) do
        {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
        _ -> to_string(raw_args)
      end

    assigns = assign(assigns, name: name, args: args_pretty)

    ~H"""
    <div class="rounded border border-base-300/40 bg-base-100/40 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 text-xs font-mono bg-base-300/30">
        <span class="text-secondary">⚙</span>
        <span class="font-semibold">{@name}</span>
      </div>
      <pre class="px-3 py-2 text-[11px] overflow-x-auto"><code phx-no-curly-interpolation><%= @args %></code></pre>
    </div>
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
