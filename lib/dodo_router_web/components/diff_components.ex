defmodule DodoRouterWeb.DiffComponents do
  @moduledoc """
  Renders `DodoRouter.TextDiff` segments.

  One renderer, because three pages now show "what changed between these
  two pieces of text" — a session's diverging turn, a replay's answer, and
  the eval builder's prompt variants — and three copies of the same colour
  choices would drift into three different meanings for the same red.
  """

  use Phoenix.Component

  alias DodoRouter.TextDiff

  @doc """
  A diff as inline insertions and deletions.

  `eq_class` dims the unchanged text: useful where the change is the point
  and the surrounding text is only there for position, wrong where the
  reader is reading the whole thing.
  """
  attr :segments, :list, required: true
  attr :mono, :boolean, default: false
  attr :eq_class, :string, default: nil
  attr :class, :string, default: nil

  def diff_block(assigns) do
    assigns = assign(assigns, :segments, TextDiff.compact_for_display(assigns.segments))

    ~H"""
    <div class={[
      "whitespace-pre-wrap break-words leading-relaxed",
      if(@mono, do: "font-mono text-xs", else: "text-sm"),
      @class
    ]}>
      <%= for {op, text} <- @segments do %>
        <%= case op do %>
          <% :eq -> %>
            <span class={@eq_class}>{text}</span>
          <% :del -> %>
            <del class="bg-error/15 text-error rounded-sm no-underline">{text}</del>
          <% :ins -> %>
            <ins class="bg-success/15 text-success rounded-sm no-underline">{text}</ins>
        <% end %>
      <% end %>
    </div>
    """
  end
end
