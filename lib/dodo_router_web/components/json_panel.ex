defmodule DodoRouterWeb.Components.JsonPanel do
  @moduledoc """
  The payload panel used wherever a log surface shows a JSON body.

  It lives here rather than inside one LiveView because the Trace, the
  conversation tab's raw views and the replay compare panes all show the same
  thing and had drifted into different presentations of it — the others still
  wearing daisyUI's `mockup-code`, which paints three fake macOS window dots
  above every payload and forces a dark panel in both themes. Decoration a log
  reader has no use for, and it cost them the collapsible tree.
  """
  use Phoenix.Component

  import DodoRouterWeb.CoreComponents

  # A payload, as a collapsible tree. The pretty-printed text stays in the markup
  # and is what renders without JS — `JsonTree` hides it and builds the tree from
  # the same string, so a payload that is not JSON (an upstream error page, a
  # truncated body) simply keeps the text it always had. daisyUI's `mockup-code`
  # used to wrap these: it painted three fake macOS window dots above every
  # payload and forced a dark panel in both themes, which is decoration a log
  # reader has no use for.
  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :copy_id, :string, default: nil
  attr :max_height, :string, default: "max-h-72"

  def json_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-end gap-1">
        <div id={"#{@id}-controls"} hidden class="flex items-center gap-1">
          <button
            type="button"
            data-json-action="expand"
            class="rounded px-1.5 py-0.5 text-[10px] font-medium text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors"
          >
            expand all
          </button>
          <button
            type="button"
            data-json-action="collapse"
            class="rounded px-1.5 py-0.5 text-[10px] font-medium text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors"
          >
            collapse all
          </button>
          <button
            type="button"
            data-json-action="raw"
            title="Show the raw JSON text"
            class="rounded px-1.5 py-0.5 text-[10px] font-medium text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors"
          >
            raw
          </button>
        </div>
        <button
          :if={@copy_id}
          id={@copy_id}
          phx-hook="CopyButton"
          data-copy={@content}
          class="rounded px-1.5 py-0.5 text-[10px] font-medium text-base-content/50 hover:bg-base-200 hover:text-primary transition-colors"
          title="Copy JSON"
        >
          <.icon name="hero-clipboard-document" class="size-3.5" />
        </button>
      </div>
      <div
        id={"#{@id}-json"}
        phx-hook="JsonTree"
        phx-update="ignore"
        data-controls={"#{@id}-controls"}
        class={[
          "rounded-lg border border-base-300/60 bg-base-200/40 p-2 overflow-auto",
          @max_height
        ]}
      >
        <pre
          data-json-fallback
          class="font-mono text-[11px] whitespace-pre-wrap break-words"
        ><code>{@content}</code></pre>
      </div>
    </div>
    """
  end
end
