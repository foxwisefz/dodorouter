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

    test "handles XML tags inside ordered lists" do
      content = "Steps:\n1. <step>First step content</step>\n2. Second step"

      parsed = MarkdownRenderer.parse(content)

      assert [
               {:paragraph, "Steps:"},
               {:list, :ordered, [[{:xml_block, "step", _}]]},
               {:list, :ordered, [[{:inline_paragraph, "Second step"}]]}
             ] = parsed
    end

    test "handles multiple XML tags in sequence" do
      content = "<tag1>content1</tag1>\n\n<tag2>content2</tag2>"

      parsed = MarkdownRenderer.parse(content)

      assert [
               {:xml_block, "tag1", _},
               {:xml_block, "tag2", _}
             ] = parsed
    end

    test "handles XML tag with list content inside" do
      content = "<example>\n- item1\n- item2\n</example>"

      parsed = MarkdownRenderer.parse(content)

      assert [{:xml_block, "example", children}] = parsed
      assert [{:list, :unordered, _}] = children
    end

    test "handles mixed XML and regular blocks" do
      content = "# Heading\n\n<note>Important</note>\n\nRegular paragraph"

      parsed = MarkdownRenderer.parse(content)

      assert [
               {:heading, 1, "Heading"},
               {:xml_block, "note", _},
               {:paragraph, "Regular paragraph"}
             ] = parsed
    end

    test "handles plain text without XML" do
      content = "Just a paragraph\n\nAnother paragraph"

      parsed = MarkdownRenderer.parse(content)

      assert [{:paragraph, "Just a paragraph"}, {:paragraph, "Another paragraph"}] = parsed
    end
  end
end
