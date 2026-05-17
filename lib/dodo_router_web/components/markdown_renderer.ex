defmodule DodoRouterWeb.MarkdownRenderer do
  @moduledoc """
  Light markdown renderer for LLM message content.

  Goals:
    * compact spacing — these are conversation logs, not blog posts
    * collapsible XML-like tags (`<task>...</task>` etc. that LLMs love to use)
    * collapsible heading sections (h2 and below)

  We deliberately don't pull in a markdown library — the feature surface we
  need (headings, bold/italic, code, lists, hr, blockquote, links) is small
  and doing it ourselves keeps full control over the collapsibility hooks.
  """
  use Phoenix.Component

  @doc """
  Render content as a markdown tree with collapsible sections.
  """
  attr :content, :any, required: true

  def render(assigns) do
    nodes =
      assigns.content
      |> to_string()
      |> parse()
      |> sectionize()

    assigns = assign(assigns, :nodes, nodes)

    ~H"""
    <div class="md-content text-sm leading-snug space-y-1.5">
      <.md_nodes nodes={@nodes} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Parsing pipeline
  # ---------------------------------------------------------------------------

  @doc false
  # Parse content into a flat list of blocks. XML tag bodies are recursively
  # parsed, producing nested `:xml_block` nodes.
  #
  # Order: block parsing first, then XML splitting within each block. This
  # ensures XML tags inside list items stay inside those list items.
  def parse(content) when is_binary(content) do
    content
    |> parse_blocks()
    |> Enum.flat_map(&split_xml_in_block/1)
  end

  # After blocks are parsed, look for XML tags inside each block.
  defp split_xml_in_block({:paragraph, text}) do
    split_xml(text)
    |> Enum.flat_map(fn
      {:text, t} ->
        trimmed = String.trim(t)
        if trimmed == "", do: [], else: [{:paragraph, trimmed}]

      {:xml, name, body} ->
        [{:xml_block, name, parse(body)}]
    end)
  end

  defp split_xml_in_block({:list, type, items}) do
    new_items =
      Enum.map(items, fn item_text ->
        split_xml(item_text)
        |> Enum.flat_map(fn
          {:text, t} ->
            trimmed = String.trim(t)
            if trimmed == "", do: [], else: [{:inline_paragraph, trimmed}]

          {:xml, name, body} ->
            [{:xml_block, name, parse(body)}]
        end)
      end)

    [{:list, type, new_items}]
  end

  defp split_xml_in_block({:blockquote, children}) do
    [{:blockquote, Enum.flat_map(children, &split_xml_in_block/1)}]
  end

  defp split_xml_in_block(block), do: [block]

  # Splits content on balanced XML-like tags (best-effort, no nesting of the
  # same tag name). Returns a list of `{:text, str} | {:xml, name, body}`.
  defp split_xml(""), do: []

  defp split_xml(content) do
    case Regex.run(~r/<([a-zA-Z][a-zA-Z0-9_:.-]*)\s*>(.*?)<\/\1>/s, content,
           return: :index,
           capture: :all
         ) do
      nil ->
        [{:text, content}]

      [{full_at, full_len}, {name_at, name_len}, {body_at, body_len}] ->
        before = binary_part(content, 0, full_at)
        name = binary_part(content, name_at, name_len)
        body = binary_part(content, body_at, body_len)
        tail_at = full_at + full_len
        tail = binary_part(content, tail_at, byte_size(content) - tail_at)
        maybe_text(before) ++ [{:xml, name, body}] ++ split_xml(tail)
    end
  end

  defp maybe_text(""), do: []
  defp maybe_text(s), do: [{:text, s}]

  # ---------------------------------------------------------------------------
  # Block parser
  # ---------------------------------------------------------------------------

  defp parse_blocks(text) do
    text
    |> String.split("\n")
    |> consume_blocks([])
    |> Enum.reverse()
  end

  defp consume_blocks([], acc), do: acc

  defp consume_blocks([line | rest] = lines, acc) do
    cond do
      blank?(line) ->
        consume_blocks(rest, acc)

      fence = code_fence(line) ->
        {code_lines, after_lines} = take_until_fence(rest, fence)
        block = {:code_block, fence.lang, Enum.join(code_lines, "\n")}
        consume_blocks(after_lines, [block | acc])

      hr?(line) ->
        consume_blocks(rest, [{:hr} | acc])

      heading = heading(line) ->
        consume_blocks(rest, [heading | acc])

      list_marker(line) ->
        {items, after_lines} = take_list(lines)
        consume_blocks(after_lines, [items | acc])

      String.starts_with?(line, ">") ->
        {bq_lines, after_lines} = take_blockquote(lines)

        body =
          bq_lines
          |> Enum.map(&String.replace_prefix(&1, ">", ""))
          |> Enum.map(&String.trim_leading/1)
          |> Enum.join("\n")

        consume_blocks(after_lines, [{:blockquote, parse_blocks(body)} | acc])

      true ->
        {para_lines, after_lines} = take_paragraph(lines)
        consume_blocks(after_lines, [{:paragraph, Enum.join(para_lines, "\n")} | acc])
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp code_fence(line) do
    case Regex.run(~r/^(\s*)(```+|~~~+)\s*([a-zA-Z0-9_+-]*)\s*$/, line) do
      [_, _, fence, lang] -> %{fence: fence, lang: lang}
      _ -> nil
    end
  end

  defp take_until_fence(lines, fence_info) do
    fence = fence_info.fence

    Enum.split_while(lines, fn line ->
      not String.match?(line, ~r/^\s*#{Regex.escape(fence)}\s*$/)
    end)
    |> case do
      {body, [_closing | rest]} -> {body, rest}
      {body, []} -> {body, []}
    end
  end

  defp hr?(line) do
    String.match?(String.trim(line), ~r/^(-{3,}|\*{3,}|_{3,})$/)
  end

  defp heading(line) do
    case Regex.run(~r/^(\#{1,6})\s+(.*?)\s*\#*\s*$/, line) do
      [_, hashes, text] -> {:heading, String.length(hashes), text}
      _ -> nil
    end
  end

  defp list_marker(line) do
    String.match?(line, ~r/^(\s*)([-*+]|\d+\.)\s+/)
  end

  defp take_list(lines) do
    {items_raw, rest} =
      Enum.split_while(lines, fn line ->
        list_marker(line) || (String.starts_with?(line, "  ") && String.trim(line) != "") ||
          blank?(line)
      end)

    # Trim trailing blanks
    items_raw = Enum.reverse(items_raw) |> Enum.drop_while(&blank?/1) |> Enum.reverse()

    items = parse_list_items(items_raw)

    type =
      case List.first(items_raw) do
        nil -> :unordered
        line -> if String.match?(line, ~r/^\s*\d+\./), do: :ordered, else: :unordered
      end

    {{:list, type, items}, rest}
  end

  defp parse_list_items(lines) do
    lines
    |> chunk_items([], [])
    |> Enum.map(&Enum.join(&1, "\n"))
    |> Enum.map(fn item_text ->
      case Regex.run(~r/^(\s*)(?:[-*+]|\d+\.)\s+(.*)/s, item_text) do
        [_, _indent, body] -> body
        _ -> item_text
      end
    end)
  end

  defp chunk_items([], current, acc) do
    case current do
      [] -> Enum.reverse(acc)
      _ -> Enum.reverse([Enum.reverse(current) | acc])
    end
  end

  defp chunk_items([line | rest], current, acc) do
    if list_marker(line) and current != [] do
      chunk_items(rest, [line], [Enum.reverse(current) | acc])
    else
      chunk_items(rest, [line | current], acc)
    end
  end

  defp take_blockquote(lines) do
    Enum.split_while(lines, fn line ->
      String.starts_with?(line, ">") || current_blockquote_continuation?(line)
    end)
  end

  # blockquote continuation: a non-blank, non-blockquote-starter line just
  # treated as a separate paragraph break, so we stop at the first non-`>` line.
  defp current_blockquote_continuation?(_), do: false

  defp take_paragraph(lines) do
    Enum.split_while(lines, fn line ->
      not blank?(line) and
        is_nil(heading(line)) and
        not hr?(line) and
        not list_marker(line) and
        is_nil(code_fence(line)) and
        not String.starts_with?(line, ">")
    end)
  end

  # ---------------------------------------------------------------------------
  # Sectionize: group blocks under headings into collapsible sections
  # ---------------------------------------------------------------------------

  @doc false
  def sectionize(blocks), do: sectionize(blocks, [])

  defp sectionize([], acc), do: Enum.reverse(acc)

  defp sectionize([{:heading, level, _text} = h | rest], acc) when level >= 1 do
    {section_blocks, remaining} = take_section(rest, level)
    section = {:section, h, sectionize(section_blocks)}
    sectionize(remaining, [section | acc])
  end

  defp sectionize([{:xml_block, name, children} | rest], acc) do
    sectionize(rest, [{:xml_block, name, sectionize(children)} | acc])
  end

  defp sectionize([block | rest], acc) do
    sectionize(rest, [block | acc])
  end

  defp take_section(blocks, level) do
    Enum.split_while(blocks, fn
      {:heading, l, _} when l <= level -> false
      _ -> true
    end)
  end

  # ---------------------------------------------------------------------------
  # Renderer
  # ---------------------------------------------------------------------------

  attr :nodes, :list, required: true

  defp md_nodes(assigns) do
    ~H"""
    <%= for node <- @nodes do %>
      <.md_node node={node} />
    <% end %>
    """
  end

  attr :node, :any, required: true

  defp md_node(%{node: {:section, {:heading, level, text}, children}} = assigns) do
    assigns =
      assigns
      |> assign(:level, level)
      |> assign(:text, text)
      |> assign(:children, children)

    ~H"""
    <details class="md-section">
      <summary class={[
        "md-summary cursor-pointer select-none flex items-center gap-1.5 py-0.5 -ml-3 pl-3",
        "hover:text-primary transition-colors list-none"
      ]}>
        <.disclosure_arrow />
        <span class={heading_class(@level)}><.inline text={@text} /></span>
      </summary>
      <div class="md-section-body pl-3 border-l border-base-300/30 mt-1 space-y-1.5">
        <.md_nodes nodes={@children} />
      </div>
    </details>
    """
  end

  defp md_node(%{node: {:xml_block, name, children}} = assigns) do
    assigns = assigns |> assign(:name, name) |> assign(:children, children)

    ~H"""
    <details class="md-xml">
      <summary class={[
        "md-xml-summary cursor-pointer select-none flex items-center gap-1.5 py-0.5 -ml-3 pl-3",
        "text-[11px] font-mono text-base-content/70 hover:text-primary list-none"
      ]}>
        <.disclosure_arrow />
        <span class="text-base-content/80 font-semibold">&lt;{@name}&gt;</span>
      </summary>
      <div class="md-xml-body pl-3 border-l border-base-content/20 mt-1 space-y-1.5">
        <.md_nodes nodes={@children} />
      </div>
    </details>
    """
  end

  defp md_node(%{node: {:heading, level, text}} = assigns) do
    assigns = assigns |> assign(:level, level) |> assign(:text, text)

    ~H"""
    <div class={heading_class(@level)}><.inline text={@text} /></div>
    """
  end

  defp md_node(%{node: {:paragraph, text}} = assigns) do
    assigns = assign(assigns, :text, normalize_paragraph(text))

    ~H"""
    <p class="break-words"><.inline text={@text} /></p>
    """
  end

  defp md_node(%{node: {:inline_paragraph, text}} = assigns) do
    assigns = assign(assigns, :text, normalize_paragraph(text))

    ~H"""
    <span class="break-words"><.inline text={@text} /></span>
    """
  end

  defp md_node(%{node: {:code_block, lang, code}} = assigns) do
    assigns = assigns |> assign(:lang, lang) |> assign(:code, code)

    ~H"""
    <pre class="my-1 overflow-x-auto rounded bg-base-300/60 p-2 text-xs"><code phx-no-curly-interpolation><%= @code %></code></pre>
    """
  end

  defp md_node(%{node: {:hr}} = assigns) do
    ~H"""
    <hr class="my-2 border-base-300/40" />
    """
  end

  defp md_node(%{node: {:list, :unordered, items}} = assigns) do
    assigns = assign(assigns, :items, items)

    ~H"""
    <ul class="list-disc pl-5 space-y-0.5 marker:text-base-content/30">
      <%= for item <- @items do %>
        <li class="break-words"><.md_nodes nodes={item} /></li>
      <% end %>
    </ul>
    """
  end

  defp md_node(%{node: {:list, :ordered, items}} = assigns) do
    assigns = assign(assigns, :items, items)

    ~H"""
    <ol class="list-decimal pl-5 space-y-0.5 marker:text-base-content/30">
      <%= for item <- @items do %>
        <li class="break-words"><.md_nodes nodes={item} /></li>
      <% end %>
    </ol>
    """
  end

  defp md_node(%{node: {:blockquote, children}} = assigns) do
    assigns = assign(assigns, :children, children)

    ~H"""
    <blockquote class="border-l-2 border-base-300/40 pl-2 text-base-content/70 italic">
      <.md_nodes nodes={@children} />
    </blockquote>
    """
  end

  defp md_node(assigns) do
    ~H""
  end

  defp disclosure_arrow(assigns) do
    ~H"""
    <svg
      class="md-arrow w-3 h-3 flex-shrink-0 text-base-content/60 transition-transform"
      viewBox="0 0 12 12"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M4 2 L8 6 L4 10 Z" />
    </svg>
    """
  end

  defp heading_class(1), do: "text-base font-semibold"
  defp heading_class(2), do: "text-sm font-semibold"
  defp heading_class(3), do: "text-sm font-semibold text-base-content/80"
  defp heading_class(_), do: "text-xs font-semibold uppercase tracking-wide text-base-content/60"

  # Collapse internal newlines/indents in a paragraph the way markdown does:
  # consecutive non-blank lines become one logical line separated by a space.
  defp normalize_paragraph(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # ---------------------------------------------------------------------------
  # Inline renderer
  # ---------------------------------------------------------------------------

  attr :text, :string, required: true

  defp inline(assigns) do
    parts = inline_tokens(assigns.text)
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <%= for part <- @parts do %>
      <.inline_part part={part} />
    <% end %>
    """
  end

  attr :part, :any, required: true

  defp inline_part(%{part: {:text, t}} = assigns) do
    assigns = assign(assigns, :t, t)
    ~H"{@t}"
  end

  defp inline_part(%{part: {:strong, parts}} = assigns) do
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <strong class="font-semibold"><.inline_parts parts={@parts} /></strong>
    """
  end

  defp inline_part(%{part: {:em, parts}} = assigns) do
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <em><.inline_parts parts={@parts} /></em>
    """
  end

  defp inline_part(%{part: {:code, t}} = assigns) do
    assigns = assign(assigns, :t, t)

    ~H"""
    <code class="px-1 py-0.5 rounded bg-base-300/60 text-[0.85em] font-mono">{@t}</code>
    """
  end

  defp inline_part(%{part: {:link, parts, url}} = assigns) do
    assigns = assigns |> assign(:parts, parts) |> assign(:url, url)

    ~H"""
    <a href={@url} target="_blank" rel="noopener" class="link link-primary">
      <.inline_parts parts={@parts} />
    </a>
    """
  end

  attr :parts, :list, required: true

  defp inline_parts(assigns) do
    ~H"""
    <%= for part <- @parts do %>
      <.inline_part part={part} />
    <% end %>
    """
  end

  # Tokenize inline: scan for **strong**, *em*, _em_, `code`, [text](url).
  # Anything else falls through as text.
  defp inline_tokens(text) when is_binary(text) do
    do_tokens(text, [])
  end

  defp do_tokens("", acc), do: Enum.reverse(acc)

  defp do_tokens(text, acc) do
    case next_token(text) do
      {:none, rest} ->
        Enum.reverse([{:text, rest} | acc])

      {:match, before, token, rest} ->
        new_acc =
          if before == "" do
            [token | acc]
          else
            [token, {:text, before} | acc]
          end

        do_tokens(rest, new_acc)
    end
  end

  # Try each inline pattern; return the earliest match.
  defp next_token(text) do
    patterns = [
      {~r/\*\*(.+?)\*\*/s, :strong},
      {~r/(?<!\w)_([^_\n]+?)_(?!\w)/, :em},
      {~r/(?<![*\w])\*([^*\n]+?)\*(?!\*)/, :em},
      {~r/`([^`\n]+?)`/, :code},
      {~r/\[([^\]]+)\]\(([^)\s]+)\)/, :link}
    ]

    candidates =
      patterns
      |> Enum.map(fn {re, kind} ->
        case Regex.run(re, text, return: :index, capture: :all) do
          nil -> nil
          captures -> {kind, captures}
        end
      end)
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] ->
        {:none, text}

      _ ->
        {kind, captures} =
          Enum.min_by(candidates, fn {_, [{at, _} | _]} -> at end)

        build_token(kind, captures, text)
    end
  end

  defp build_token(kind, [{full_at, full_len} | rest_captures], text) do
    before = binary_part(text, 0, full_at)
    tail_at = full_at + full_len
    rest = binary_part(text, tail_at, byte_size(text) - tail_at)

    token =
      case {kind, rest_captures} do
        {:strong, [{at, len}]} ->
          {:strong, inline_tokens(binary_part(text, at, len))}

        {:em, [{at, len}]} ->
          {:em, inline_tokens(binary_part(text, at, len))}

        {:code, [{at, len}]} ->
          {:code, binary_part(text, at, len)}

        {:link, [{tat, tlen}, {uat, ulen}]} ->
          {:link, inline_tokens(binary_part(text, tat, tlen)), binary_part(text, uat, ulen)}
      end

    {:match, before, token, rest}
  end
end
