defmodule DodoRouterWeb.MarkdownRendererTest do
  use ExUnit.Case, async: true

  alias DodoRouterWeb.MarkdownRenderer

  describe "parse/1" do
    test "keeps XML tags inside list items" do
      content = "Examples:\n- <example>\n  Context: test</example>"

      parsed = MarkdownRenderer.parse(content)

      # Should be a paragraph + list, not paragraph + empty list + xml_block
      assert [{:paragraph, "Examples:"}, {:list, :unordered, [item]}] = parsed
      # The list item should contain the xml_block, not be empty
      assert [{:xml_block, "example", _}] = item
    end

    test "parses XML tags as separate blocks outside lists" do
      content = "# Heading\n<example>\ntext\n</example>\n\nParagraph"

      parsed = MarkdownRenderer.parse(content)

      assert [
               {:heading, 1, "Heading"},
               {:xml_block, "example", [{:paragraph, "text"}]},
               {:paragraph, "Paragraph"}
             ] = parsed
    end

    test "handles mixed content in list items" do
      content = "- First item\n- <example>content</example>\n- Third item"

      parsed = MarkdownRenderer.parse(content)

      assert [{:list, :unordered, items}] = parsed
      assert [item1, item2, item3] = items

      # First item should be plain text
      assert [{:inline_paragraph, "First item"}] = item1

      # Second item should contain the XML block
      assert [{:xml_block, "example", _}] = item2

      # Third item should be plain text
      assert [{:inline_paragraph, "Third item"}] = item3
    end
  end
end
