defmodule DodoRouterWeb.PromptComponentsTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouterWeb.PromptComponents

  describe "conversation/1" do
    test "renders messages with tool calls" do
      assigns = %{
        messages: [
          %{role: "user", content: "Hello", tool_calls: nil},
          %{
            role: "assistant",
            content: "Let me help",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "bash",
                  "arguments" => Jason.encode!(%{"command" => "ls -la"})
                }
              }
            ]
          }
        ],
        response: nil,
        model: "gpt-4",
        provider: "openai",
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "Hello"
      assert html =~ "Let me help"
      assert html =~ "bash"
      assert html =~ "ls -la"
    end

    test "renders tool results inline with tool calls" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "read_file",
                  "arguments" => Jason.encode!(%{"file_path" => "/etc/hosts"})
                }
              }
            ]
          },
          %{
            role: "tool",
            content: "127.0.0.1 localhost",
            tool_call_id: "call_1"
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "read_file"
      assert html =~ "/etc/hosts"
      assert html =~ "127.0.0.1 localhost"
    end

    test "uses heuristic rendering for command tools" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "bash",
                  "arguments" =>
                    Jason.encode!(%{
                      "command" => "echo hello",
                      "description" => "Say hello"
                    })
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "bash"
      assert html =~ "echo hello"
      assert html =~ "Say hello"
      refute html =~ "{@command}"
    end

    test "uses heuristic rendering for file tools" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "read_file",
                  "arguments" => Jason.encode!(%{"file_path" => "/tmp/test.txt"})
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "read_file"
      assert html =~ "/tmp/test.txt"
      refute html =~ "{@path}"
    end

    test "uses heuristic rendering for risk tools" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "execute_command",
                  "arguments" =>
                    Jason.encode!(%{
                      "command" => "rm -rf /",
                      "riskLevel" => "high",
                      "timeout" => 30
                    })
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "execute_command"
      assert html =~ "rm -rf /"
      assert html =~ "high"
      assert html =~ "30"
      refute html =~ "{@command}"
    end

    test "uses heuristic rendering for question tools" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "ask_user",
                  "arguments" =>
                    Jason.encode!(%{
                      "questions" => ["What is your name?"],
                      "options" => [%{"label" => "Option 1"}, %{"label" => "Option 2"}]
                    })
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "ask_user"
      assert html =~ "What is your name?"
      assert html =~ "Option 1"
      assert html =~ "Option 2"
    end

    test "falls back to generic rendering for unknown tools" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "custom_tool",
                  "arguments" => Jason.encode!(%{"key" => "value"})
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "custom_tool"
    end

    test "handles invalid JSON arguments gracefully" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "broken",
                  "arguments" => "not valid json"
                }
              }
            ]
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)
      assert html =~ "broken"
    end

    test "filters out tool result messages from display" do
      assigns = %{
        messages: [
          %{role: "user", content: "Test", tool_calls: nil},
          %{
            role: "tool",
            content: "result",
            tool_call_id: "call_1"
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "Test"
      refute html =~ "result"
    end

    test "shows available tools section" do
      assigns = %{
        messages: [],
        response: nil,
        model: nil,
        provider: nil,
        tools: [
          %{name: "tool1"},
          %{name: "tool2"}
        ]
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "Tools"
      assert html =~ "2 available"
      assert html =~ "tool1"
      assert html =~ "tool2"
    end
  end

  describe "message_at/2" do
    test "returns message at valid index" do
      segments = [
        %{message: %{role: "user", content: "hi"}},
        %{message: %{role: "assistant", content: "hello"}}
      ]

      assert %{role: "user", content: "hi"} = PromptComponents.message_at(segments, 0)
      assert %{role: "assistant", content: "hello"} = PromptComponents.message_at(segments, 1)
    end

    test "returns nil for out of bounds index" do
      segments = [%{message: %{role: "user", content: "hi"}}]

      assert PromptComponents.message_at(segments, -1) == nil
      assert PromptComponents.message_at(segments, 1) == nil
      assert PromptComponents.message_at(segments, 100) == nil
    end

    test "returns nil for empty segments" do
      assert PromptComponents.message_at([], 0) == nil
    end
  end
end
