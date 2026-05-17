defmodule DodoRouterWeb.PromptComponentsTest do
  use DodoRouterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DodoRouterWeb.PromptComponents

  describe "conversation/1" do
    test "renders basic messages" do
      assigns = %{
        messages: [
          %{role: "user", content: "Hello", tool_calls: nil},
          %{role: "assistant", content: "Hi there", tool_calls: nil}
        ],
        response: nil,
        model: "gpt-4",
        provider: "openai",
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ "openai"
      assert html =~ "gpt-4"
      assert html =~ "Hello"
      assert html =~ "Hi there"
    end

    test "renders user messages right-aligned" do
      assigns = %{
        messages: [%{role: "user", content: "Test", tool_calls: nil}],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)
      assert html =~ "items-end"
    end

    test "renders assistant messages left-aligned" do
      assigns = %{
        messages: [%{role: "assistant", content: "Response", tool_calls: nil}],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)
      assert html =~ "items-start"
    end
  end

  describe "conversation/1 with tool calls" do
    test "renders command tool with actual command in code block" do
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
                      "command" => "ls -la /tmp",
                      "description" => "List tmp directory"
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

      assert html =~ ~s(<code>ls -la /tmp</code>),
             "Expected command 'ls -la /tmp' inside <code> tag"

      refute html =~ "{@command}",
             "Found literal {@command} in output — interpolation not working"

      assert html =~ "List tmp directory"
      assert html =~ "bash"
    end

    test "renders file tool with path in code block" do
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
          }
        ],
        response: nil,
        model: nil,
        provider: nil,
        tools: []
      }

      html = render_component(&PromptComponents.conversation/1, assigns)

      assert html =~ ~s(<code>/etc/hosts</code>),
             "Expected path '/etc/hosts' inside <code> tag"

      refute html =~ "{@path}",
             "Found literal {@path} in output — interpolation not working"

      assert html =~ "read_file"
    end

    test "renders risk tool with risk badge and command" do
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
                      "timeout" => 30,
                      "description" => "Dangerous command"
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

      assert html =~ ~s(<code>rm -rf /</code>),
             "Expected command 'rm -rf /' inside <code> tag"

      refute html =~ "{@command}",
             "Found literal {@command} in output — interpolation not working"

      assert html =~ "execute_command"
      assert html =~ "Dangerous command"
      assert html =~ "high"
      assert html =~ "30"
    end

    test "renders question tool with questions and options" do
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
                      "questions" => ["What is your name?", "How old are you?"],
                      "options" => [%{"label" => "Option A"}, %{"label" => "Option B"}]
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
      assert html =~ "How old are you?"
      assert html =~ "Option A"
      assert html =~ "Option B"
    end

    test "handles string questions (not just maps)" do
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
                      "questions" => ["Simple question"],
                      "options" => ["Yes", "No"]
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

      assert html =~ "Simple question"
      assert html =~ "Yes"
      assert html =~ "No"
    end

    test "falls back to generic rendering for unknown tool types" do
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
                  "arguments" => Jason.encode!(%{"key" => "value", "number" => 42})
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
      assert html =~ "key"
      assert html =~ "value"
      assert html =~ "42"
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

      assert html =~ "127.0.0.1 localhost"
      assert html =~ "result"
      assert html =~ "items-start"
      refute html =~ "tool result"
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

    test "handles missing command field by falling back to generic" do
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
                  "arguments" => Jason.encode!(%{"description" => "No command"})
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
      assert html =~ "No command"
      assert html =~ "description"
    end

    test "filters out tool result messages from display" do
      assigns = %{
        messages: [
          %{role: "user", content: "Test", tool_calls: nil},
          %{
            role: "tool",
            content: "secret result data",
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
      refute html =~ "secret result data"
    end

    test "shows available tools section" do
      assigns = %{
        messages: [],
        response: nil,
        model: nil,
        provider: nil,
        tools: [
          %{name: "tool1"},
          %{name: "tool2"},
          %{name: "tool3"}
        ]
      }

      html = render_component(&PromptComponents.conversation/1, assigns)
      assert html =~ "Tools"
      assert html =~ "3 available"
      assert html =~ "tool1"
      assert html =~ "tool2"
      assert html =~ "tool3"
      assert html =~ "phx-click=\"show_tool\""
    end
  end

  describe "message_at/2" do
    test "returns message at valid index" do
      segments = [
        %{message: %{role: "user", content: "hi"}},
        %{message: %{role: "assistant", content: "hello"}},
        %{message: %{role: "user", content: "bye"}}
      ]

      assert %{role: "user", content: "hi"} = PromptComponents.message_at(segments, 0)
      assert %{role: "assistant", content: "hello"} = PromptComponents.message_at(segments, 1)
      assert %{role: "user", content: "bye"} = PromptComponents.message_at(segments, 2)
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

  describe "tool_icon/1" do
    test "returns consistent icon for same name" do
      icon1 = PromptComponents.tool_icon("bash")
      icon2 = PromptComponents.tool_icon("bash")

      assert icon1 == icon2
      assert is_binary(icon1)
      assert String.starts_with?(icon1, "hero-")
    end

    test "returns different icons for different names" do
      icon1 = PromptComponents.tool_icon("bash")
      icon2 = PromptComponents.tool_icon("read_file")

      assert String.starts_with?(icon1, "hero-")
      assert String.starts_with?(icon2, "hero-")
    end
  end
end
