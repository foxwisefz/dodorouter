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

    test "handles XML tags inside list items" do
      content = "Examples:\n- <example>content</example>"

      parsed = MarkdownRenderer.parse(content)

      assert [{:paragraph, "Examples:"}, {:list, :unordered, [item]}] = parsed
      assert [{:xml_block, "example", _}] = item
    end

    test "handles multi-block XML tags like system-reminder" do
      content =
        "<system-reminder>\n- gemini-marketing: ...\n- landing-pages: ...\n</system-reminder>\n\nhi"

      parsed = MarkdownRenderer.parse(content)

      # Should extract the entire system-reminder as one XML block
      assert [{:xml_block, "system-reminder", _}, {:paragraph, "hi"}] = parsed
    end
  end
end
