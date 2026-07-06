defmodule DodoRouterWeb.PromptComponents do
  @moduledoc """
  Components for rendering LLM conversations on the private log detail page.
  """
  use Phoenix.Component

  import DodoRouterWeb.CoreComponents
  import DodoRouterWeb.ProviderIcons

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
  attr :cache_read_tokens, :integer, default: nil
  attr :cache_write_tokens, :integer, default: nil
  attr :replay_base, :string, default: nil

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

    # Compute which messages are in the cached prefix. We use explicit cache_control
    # markers (Anthropic-style) when available; otherwise we estimate the boundary
    # from cache_read_tokens / prompt_tokens using a simple content-length heuristic.
    all_messages = system_messages ++ display_messages

    cache_info =
      compute_cache_info(all_messages, assigns.cache_read_tokens, assigns.cache_write_tokens)

    assigns =
      assigns
      |> assign(:system_messages, system_messages)
      |> assign(:display_messages, display_messages)
      |> assign(:tool_results, tool_results)
      |> assign(:cached_indices, cache_info.cached_indices)
      |> assign(:breakpoint_idx, cache_info.breakpoint_idx)
      |> assign(:breakpoint_estimated, cache_info.estimated)
      |> assign(:display_index_offset, length(system_messages))

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
          <%= if @cache_read_tokens && @cache_read_tokens > 0 do %>
            <span class="ml-auto inline-flex items-center gap-1 text-success bg-success/10 px-2 py-0.5 rounded">
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              {@cache_read_tokens} cached tokens
            </span>
          <% end %>
        </div>
      <% end %>

      <div class="space-y-3">
        <%!-- The dialogue is what a log reader came for; the system preamble
             (often thousands of tokens) folds into one row --%>
        <details :if={@system_messages != []} class="system-block group">
          <summary class="cursor-pointer select-none list-none flex items-center gap-2 rounded-lg border border-base-300/40 bg-base-200/40 px-3 py-2 text-xs text-base-content/60 hover:text-base-content transition-colors">
            <.icon
              name="hero-chevron-right"
              class="w-3 h-3 shrink-0 transition-transform group-open:rotate-90"
            />
            <span class="font-medium">System prompt</span>
            <span class="text-base-content/40">
              {pluralize(length(@system_messages), "message")} · {system_chars(@system_messages)} chars
            </span>
            <span
              :if={
                MapSet.size(@cached_indices) >= length(@system_messages) and @system_messages != []
              }
              class="ml-auto text-[10px] px-1.5 py-0.5 rounded bg-success/10 text-success font-medium"
            >
              cached
            </span>
          </summary>
          <div class="mt-2 space-y-3">
            <.collapsed_message_list
              messages={@system_messages}
              id_prefix="sys"
              response={false}
              tool_results={%{}}
              cached_indices={@cached_indices}
              breakpoint_idx={@breakpoint_idx}
              breakpoint_estimated={@breakpoint_estimated}
            />
          </div>
        </details>

        <%= if length(@tools) > 0 do %>
          <.available_tools tools={@tools} />
        <% end %>

        <.collapsed_message_list
          messages={@display_messages}
          response={@response}
          tool_results={@tool_results}
          cached_indices={@cached_indices}
          breakpoint_idx={@breakpoint_idx}
          breakpoint_estimated={@breakpoint_estimated}
          index_offset={@display_index_offset}
          replay_base={@replay_base}
        />
      </div>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :response, :any, default: nil
  attr :tool_results, :map, default: %{}
  attr :cached_indices, :any, default: MapSet.new()
  attr :breakpoint_idx, :integer, default: nil
  attr :breakpoint_estimated, :boolean, default: false
  attr :index_offset, :integer, default: 0
  attr :replay_base, :string, default: nil
  # Namespaces DOM ids: the conversation renders two of these lists (system +
  # dialogue) whose indexes both start at 0, so ids must not collide.
  attr :id_prefix, :string, default: "msg"

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
      <% real_index = if is_integer(seg.index), do: @index_offset + seg.index, else: seg.index %>
      <.message_bubble
        message={seg.message}
        index={seg.index}
        id_prefix={@id_prefix}
        response={seg.response}
        next_message={message_at(@segments, idx + 1)}
        prev_message={message_at(@segments, idx - 1)}
        tool_results={@tool_results}
        cached={is_cached?(real_index, @cached_indices)}
        replay_base={@replay_base}
      />
      <.cache_breakpoint
        :if={is_breakpoint_here?(real_index, @breakpoint_idx) or has_cache_control?(seg.message)}
        estimated={@breakpoint_estimated and not has_cache_control?(seg.message)}
      />
    <% end %>
    """
  end

  defp is_cached?(index, _cached_indices) when not is_integer(index), do: false
  defp is_cached?(index, cached_indices), do: MapSet.member?(cached_indices, index)

  defp has_cache_control?(message), do: Map.get(message, :cache_control) != nil

  defp is_breakpoint_here?(index, breakpoint_idx)
       when is_integer(index) and is_integer(breakpoint_idx) and index == breakpoint_idx,
       do: true

  defp is_breakpoint_here?(_, _), do: false

  @approx_chars_per_token 4

  defp compute_cache_info(messages, cache_read_tokens, cache_write_tokens) do
    explicit_breakpoint_idx =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _} -> not is_nil(Map.get(msg, :cache_control)) end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> List.last()

    if is_integer(explicit_breakpoint_idx) and (cache_read_tokens || 0) > 0 do
      %{
        cached_indices: MapSet.new(0..explicit_breakpoint_idx),
        breakpoint_idx: explicit_breakpoint_idx,
        estimated: false
      }
    else
      estimate_cache_boundary(messages, cache_read_tokens, cache_write_tokens)
    end
  end

  defp estimate_cache_boundary(_messages, nil, nil),
    do: %{cached_indices: MapSet.new(), breakpoint_idx: nil, estimated: false}

  defp estimate_cache_boundary(messages, cache_read_tokens, cache_write_tokens) do
    total_cache = (cache_read_tokens || 0) + (cache_write_tokens || 0)

    if total_cache > 0 do
      indexed_estimates =
        Enum.with_index(messages)
        |> Enum.map(fn {msg, idx} ->
          {idx, estimate_message_tokens(msg)}
        end)

      total_prompt_tokens = Enum.sum(Enum.map(indexed_estimates, &elem(&1, 1)))

      # If cached tokens cover the whole prompt, everything is cached.
      if total_cache >= total_prompt_tokens do
        %{
          cached_indices: MapSet.new(0..(length(messages) - 1)),
          breakpoint_idx: length(messages) - 1,
          estimated: true
        }
      else
        # Accumulate tokens from the start and find the message that crosses the cache boundary.
        breakpoint_idx =
          Enum.reduce_while(indexed_estimates, nil, fn {idx, tokens}, acc ->
            prev_acc = acc || 0
            new_acc = prev_acc + tokens

            if new_acc >= total_cache do
              {:halt, idx}
            else
              {:cont, new_acc}
            end
          end)

        cached_indices =
          if is_integer(breakpoint_idx) and breakpoint_idx >= 0 do
            MapSet.new(0..breakpoint_idx)
          else
            MapSet.new()
          end

        %{cached_indices: cached_indices, breakpoint_idx: breakpoint_idx, estimated: true}
      end
    else
      %{cached_indices: MapSet.new(), breakpoint_idx: nil, estimated: false}
    end
  end

  defp estimate_message_tokens(message) do
    content = message.content || ""

    text =
      cond do
        is_binary(content) -> content
        is_list(content) -> Enum.join(content, " ")
        true -> ""
      end

    # Crude approximation: ~4 chars per token on average.
    max(1, trunc(String.length(text) / @approx_chars_per_token))
  end

  attr :estimated, :boolean, default: false

  defp cache_breakpoint(assigns) do
    label = if assigns.estimated, do: "Estimated cache boundary", else: "Cache breakpoint"

    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="relative flex items-center gap-3 py-2 my-1 px-4">
      <div class="flex-1 border-t-2 border-dashed border-success/40"></div>
      <div class="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-success bg-success/10 px-2.5 py-1 rounded-full">
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 10V3L4 14h7v7l9-11h-7z"
          />
        </svg>
        {@label}
      </div>
      <div class="flex-1 border-t-2 border-dashed border-success/40"></div>
    </div>
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
  attr :id_prefix, :string, default: "msg"
  attr :response, :boolean, default: false
  attr :next_message, :map, default: nil
  attr :prev_message, :map, default: nil
  attr :tool_results, :map, default: %{}
  attr :cached, :boolean, default: false
  attr :replay_base, :string, default: nil

  defp message_bubble(assigns) do
    role = assigns.message.role
    {bubble_class, label_class, label} = role_styles(role, assigns.response)

    assigns =
      assigns
      |> assign(:bubble_class, bubble_class)
      |> assign(:label_class, label_class)
      |> assign(:label, label)
      |> assign(:role, role)
      |> assign(:has_cache_control, Map.get(assigns.message, :cache_control) != nil)
      |> assign(:producer, Map.get(assigns.message, :producer))

    ~H"""
    <div
      id={bubble_dom_id(@message)}
      phx-hook={if Map.get(@message, :highlighted), do: "ScrollIntoView"}
      class={[
        "group flex flex-col gap-1.5",
        align_class(@role),
        Map.get(@message, :highlighted) && "ring-2 ring-info/40 rounded-xl p-2 -m-2"
      ]}
    >
      <div class="flex items-center gap-2 px-1">
        <span class={"text-[10px] uppercase tracking-wider font-semibold #{@label_class}"}>
          {@label}
        </span>
        <.link
          :if={@producer}
          navigate={"/logs/#{@producer.log_id}"}
          class="text-[10px] px-1.5 py-0.5 rounded bg-secondary/40 text-base-content/50 hover:text-primary font-medium inline-flex items-center gap-1 transition-colors"
          title={"Produced by #{@producer.provider}/#{@producer.model}"}
        >
          <.provider_logo slug={normalize_slug(@producer.provider || "unknown")} class="w-2.5 h-2.5" />
          {@producer.model}
        </.link>
        <%= if @cached do %>
          <span class="text-[10px] px-1.5 py-0.5 rounded bg-success/10 text-success font-medium">
            cached
          </span>
        <% end %>
        <%= if @has_cache_control do %>
          <span class="text-[10px] px-1.5 py-0.5 rounded bg-success/10 text-success font-medium">
            cache breakpoint
          </span>
        <% end %>
        <%= if is_binary(@message.content) && @message.content != "" do %>
          <button
            type="button"
            id={"copy-#{@id_prefix}-#{@index}"}
            phx-hook="CopyButton"
            data-copy={@message.content}
            class="text-base-content/25 hover:text-primary transition-colors"
            title="Copy raw message"
          >
            <.icon name="hero-clipboard-document" class="w-3 h-3" />
          </button>
        <% end %>
        <.link
          :if={@replay_base && @role == "user" && Map.get(@message, :abs_index)}
          navigate={"#{@replay_base}?from=#{@message.abs_index}"}
          class="text-base-content/25 hover:text-primary transition-colors"
          title="Replay the conversation from this message with another model"
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" />
        </.link>
      </div>

      <div class={"max-w-[85%] rounded-2xl px-4 py-3 shadow-sm #{@bubble_class}"}>
        <details
          :if={is_binary(Map.get(@message, :reasoning_content)) && @message.reasoning_content != ""}
          class="reasoning-block group mb-2 rounded-lg border border-base-300/40 bg-base-100/50"
        >
          <summary class="cursor-pointer select-none px-3 py-1.5 text-[11px] font-medium text-base-content/50 hover:text-base-content/80 transition-colors list-none flex items-center gap-1.5">
            <.icon
              name="hero-chevron-right"
              class="w-3 h-3 transition-transform group-open:rotate-90"
            /> Reasoning
          </summary>
          <div class="px-3 pb-2.5 text-xs leading-relaxed text-base-content/60 whitespace-pre-wrap">
            {@message.reasoning_content}
          </div>
        </details>
        <div class="max-w-none">
          <MarkdownRenderer.render content={@message.content} open_sections={@response} />
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

  # NB: text-secondary is invisible here — `secondary` is a surface tint in
  # this design system (96% white / 14% black), not a text accent
  defp role_styles("assistant", true),
    do: {"bg-base-200 border border-base-300/40", "text-base-content/70", "assistant"}

  defp role_styles("assistant", false),
    do: {"bg-base-200/60 border border-base-300/30", "text-base-content/50", "assistant"}

  defp role_styles("system", _),
    do: {"bg-base-300/40 text-base-content/70", "text-base-content/40", "system"}

  defp role_styles("tool", _),
    do: {"bg-warning/10 border border-warning/30", "text-warning", "tool result"}

  defp role_styles(other, _), do: {"bg-base-200", "text-base-content/40", other || "msg"}

  defp bubble_dom_id(message) do
    case Map.get(message, :abs_index) do
      nil -> nil
      index -> "message-#{index}"
    end
  end

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
    <details class="group px-4 py-1" open={length(@tools) <= 8}>
      <summary class="cursor-pointer select-none list-none flex items-center gap-2 py-1 text-base-content/40 hover:text-base-content/70 transition-colors">
        <.icon
          name="hero-chevron-right"
          class="w-3 h-3 shrink-0 transition-transform group-open:rotate-90"
        />
        <span class="text-[10px] uppercase tracking-wider font-semibold">Tools</span>
        <span class="text-[10px] text-base-content/30">{length(@tools)} available</span>
      </summary>
      <div class="flex flex-wrap gap-1.5 mt-1.5">
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
    </details>
    """
  end

  defp system_chars(messages) do
    messages
    |> Enum.map(fn m -> m.content |> to_string() |> String.length() end)
    |> Enum.sum()
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
