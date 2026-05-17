defmodule DodoRouter.Logs.MessageNormalizerTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Logs.MessageNormalizer

  describe "extract_tools/1" do
    test "extracts OpenAI-style function tools" do
      params = %{
        "tools" => [
          %{
            "function" => %{
              "name" => "search",
              "description" => "Search the web",
              "parameters" => %{"type" => "object"}
            }
          }
        ]
      }

      assert [%{name: "search", description: "Search the web", parameters: %{"type" => "object"}}] =
               MessageNormalizer.extract_tools(params)
    end

    test "extracts Anthropic-style tools" do
      params = %{
        "tools" => [
          %{
            "name" => "calculator",
            "description" => "Do math",
            "input_schema" => %{"type" => "object"}
          }
        ]
      }

      assert [%{name: "calculator", description: "Do math", parameters: %{"type" => "object"}}] =
               MessageNormalizer.extract_tools(params)
    end

    test "returns empty list when no tools" do
      assert [] = MessageNormalizer.extract_tools(%{})
      assert [] = MessageNormalizer.extract_tools(%{"tools" => []})
    end

    test "normalizes descriptions with escaped newlines" do
      params = %{
        "tools" => [
          %{
            "function" => %{
              "name" => "test",
              "description" => "Line 1\\nLine 2\\nLine 3",
              "parameters" => %{}
            }
          }
        ]
      }

      assert [%{description: "Line 1\nLine 2\nLine 3"}] = MessageNormalizer.extract_tools(params)
    end
  end
end
