defmodule DodoRouterWeb.PromptComponents do
  @moduledoc """
  Components for rendering LLM conversations as a hero, share-worthy artifact
  rather than a debug pane. Used by the public sharing pages and by the
  Conversation tab on the private log detail.
  """
  use Phoenix.Component

  @doc """
  A chat-bubble style conversation view.

  ## Attributes

    * `:messages` — list of normalized request messages (role/content/tool_calls)
    * `:response` — the assistant response message (or nil)
    * `:model` — display string e.g. "gpt-4"
    * `:provider` — display string e.g. "openai"
    * `:editable` — when true, renders messages as editable textareas and
      surfaces "Run with my keys" controls. The parent LiveView is expected to
      handle `edit_message`, `add_turn`, `remove_turn`, and `run_fork` events.
    * `:edited_messages` — when editable, the working copy of the messages
      (defaults to `:messages` if not provided).
  """
  attr :messages, :list, required: true
  attr :response, :any, default: nil
  attr :model, :string, default: nil
  attr :provider, :string, default: nil
  attr :editable, :boolean, default: false
  attr :edited_messages, :list, default: nil
  attr :run_disabled, :boolean, default: false
  attr :run_label, :string, default: "Run with my keys"

  slot :run_controls,
    doc: "Optional slot for additional controls (e.g. router/key picker) shown above the Run button."

  def conversation(assigns) do
    assigns =
      assign_new(assigns, :working_messages, fn ->
        assigns.edited_messages || assigns.messages
      end)

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
        <%= for {msg, idx} <- Enum.with_index(@working_messages) do %>
          <.message_bubble message={msg} index={idx} editable={@editable} />
        <% end %>

        <%= if @response do %>
          <.message_bubble message={@response} index="response" editable={false} response={true} />
        <% end %>
      </div>

      <%= if @editable do %>
        <div class="border-t border-base-300/50 pt-4 space-y-3">
          <div class="flex items-center gap-2">
            <button type="button" phx-click="add_turn" phx-value-role="user" class="btn btn-sm btn-ghost">
              + Add user turn
            </button>
            <button type="button" phx-click="add_turn" phx-value-role="assistant" class="btn btn-sm btn-ghost">
              + Add assistant turn
            </button>
            <button type="button" phx-click="reset_messages" class="btn btn-sm btn-ghost ml-auto">
              ↻ Reset
            </button>
          </div>

          {render_slot(@run_controls)}

          <button
            type="button"
            phx-click="run_fork"
            disabled={@run_disabled}
            class="btn btn-primary btn-block"
          >
            <span class="text-base">▶</span>
            {@run_label}
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :index, :any, required: true
  attr :editable, :boolean, default: false
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
        <%= if @editable do %>
          <button
            type="button"
            phx-click="remove_turn"
            phx-value-index={@index}
            class="text-[10px] text-base-content/30 hover:text-error opacity-0 group-hover:opacity-100 transition"
            title="Remove this turn"
          >
            remove
          </button>
        <% end %>
      </div>

      <div class={"max-w-[85%] rounded-2xl px-4 py-3 shadow-sm #{@bubble_class}"}>
        <%= if @editable do %>
          <textarea
            phx-blur="edit_message"
            phx-value-index={@index}
            name="content"
            class="w-full bg-transparent border-0 outline-none resize-none text-sm leading-relaxed font-sans focus:ring-0"
            rows={textarea_rows(@message.content)}
          >{@message.content}</textarea>
        <% else %>
          <div class="prose prose-sm max-w-none">
            {render_content(@message.content)}
          </div>
        <% end %>

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
    do: {"bg-base-300/40 text-base-content/70 italic", "text-base-content/40", "system"}

  defp role_styles("tool", _),
    do: {"bg-warning/10 border border-warning/30", "text-warning", "tool result"}

  defp role_styles(other, _), do: {"bg-base-200", "text-base-content/40", other || "msg"}

  defp align_class("user"), do: "items-end"
  defp align_class(_), do: "items-start"

  defp textarea_rows(content) when is_binary(content) do
    lines = String.split(content, "\n") |> length()
    max(2, min(20, lines + 1))
  end

  defp textarea_rows(_), do: 3

  # Render content with simple fenced-code-block detection. We don't pull in a
  # markdown lib — just split on triple backticks and render odd-indexed
  # segments as <pre><code> blocks.
  defp render_content(content) when is_binary(content) do
    parts = Regex.split(~r/```(?:[a-zA-Z0-9_+-]*\n)?/, content, trim: false)

    assigns = %{parts: parts}

    ~H"""
    <%= for {part, idx} <- Enum.with_index(@parts) do %>
      <%= if rem(idx, 2) == 0 do %>
        <p class="whitespace-pre-wrap break-words text-sm leading-relaxed">{part}</p>
      <% else %>
        <pre class="my-2 overflow-x-auto rounded bg-base-300/60 p-3 text-xs"><code phx-no-curly-interpolation>{part}</code></pre>
      <% end %>
    <% end %>
    """
  end

  defp render_content(other) do
    assigns = %{other: inspect(other)}

    ~H"""
    <p class="whitespace-pre-wrap break-words text-sm font-mono">{@other}</p>
    """
  end

  attr :call, :map, required: true

  defp tool_call_card(assigns) do
    name = get_in(assigns.call, ["function", "name"]) || assigns.call["name"] || "tool"
    raw_args = get_in(assigns.call, ["function", "arguments"]) || assigns.call["arguments"] || "{}"

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
      <pre class="px-3 py-2 text-[11px] overflow-x-auto"><code phx-no-curly-interpolation>{@args}</code></pre>
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
      📍 {@log.public_title || "log #{String.slice(@log.id, 0, 8)}"}
    </.link>
    """
  end

  defp role_color("user"), do: "text-primary"
  defp role_color("assistant"), do: "text-secondary"
  defp role_color("system"), do: "text-base-content/40"
  defp role_color("tool"), do: "text-warning"
  defp role_color(_), do: "text-base-content/40"

  @doc """
  Modal for the publish flow. Shows the redaction-snapshotted bodies and
  takes a title.
  """
  attr :id, :string, default: "publish-modal"
  attr :show, :boolean, default: false
  attr :log, :map, required: true
  attr :preview_messages, :list, required: true

  def publish_modal(assigns) do
    ~H"""
    <div :if={@show} id={@id} class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <h3 class="font-bold text-lg">Publish this prompt</h3>
        <p class="text-sm text-base-content/60 mt-1">
          A public, read-only URL anyone can visit. Logged-in viewers can fork it and run against their own keys.
        </p>

        <form phx-submit="confirm_publish" class="mt-4 space-y-4">
          <div>
            <label class="label" for="publish-title">
              <span class="label-text">Title</span>
            </label>
            <input
              id="publish-title"
              name="title"
              type="text"
              maxlength="200"
              placeholder="e.g. ELI5 explanation of monads"
              class="input input-bordered w-full"
            />
          </div>

          <details class="bg-base-200/40 rounded p-3">
            <summary class="cursor-pointer text-sm font-medium">Preview redacted snapshot</summary>
            <div class="mt-3 max-h-80 overflow-y-auto space-y-2 text-xs">
              <%= for msg <- @preview_messages do %>
                <div class="flex gap-2">
                  <span class="font-mono text-base-content/40 uppercase text-[10px]">{msg.role}</span>
                  <p class="whitespace-pre-wrap break-words flex-1">{msg.content}</p>
                </div>
              <% end %>
            </div>
            <p class="text-[11px] text-base-content/50 mt-2">
              API keys, JWTs, AWS credentials, and similar secrets are redacted automatically.
              Review carefully — you can unpublish at any time.
            </p>
          </details>

          <div class="modal-action">
            <button type="button" phx-click="cancel_publish" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Publish</button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="cancel_publish"></div>
    </div>
    """
  end
end
