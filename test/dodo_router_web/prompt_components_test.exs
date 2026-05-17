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

  describe "tool call argument rendering" do
    test "command tool renders command argument in code block" do
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

      assert html =~ ~s(<code>ls -la /tmp</code>)
      refute html =~ "{@command}"
      assert html =~ "List tmp directory"
      assert html =~ "bash"
    end

    test "file tool renders file_path argument in code block" do
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

      assert html =~ ~s(<code>/etc/hosts</code>)
      refute html =~ "{@path}"
      assert html =~ "read_file"
    end

    test "file tool falls back to path when file_path missing" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "write_file",
                  "arguments" => Jason.encode!(%{"path" => "/tmp/test.txt"})
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

      assert html =~ ~s(<code>/tmp/test.txt</code>)
      assert html =~ "write_file"
    end

    test "risk tool renders command, risk level, and timeout" do
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

      assert html =~ ~s(<code>rm -rf /</code>)
      refute html =~ "{@command}"
      assert html =~ "execute_command"
      assert html =~ "Dangerous command"
      assert html =~ "high"
      assert html =~ "30"
    end

    test "risk tool handles unknown risk level" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "run",
                  "arguments" =>
                    Jason.encode!(%{
                      "command" => "echo test",
                      "riskLevel" => "critical"
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

      assert html =~ "critical"
      assert html =~ ~s(<code>echo test</code>)
    end

    test "question tool renders questions and options" do
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

    test "question tool handles string questions and options" do
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

    test "generic tool renders JSON arguments" do
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

    test "handles invalid JSON arguments" do
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

    test "handles missing fields gracefully" do
      assigns = %{
        messages: [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "function" => %{
                  "name" => "minimal_tool",
                  "arguments" => Jason.encode!(%{})
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
      assert html =~ "minimal_tool"
    end

    test "renders tool results inline" do
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
      refute html =~ "tool result"
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
  end

  describe "available tools" do
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

    test "returns valid icons for different names" do
      icon1 = PromptComponents.tool_icon("bash")
      icon2 = PromptComponents.tool_icon("read_file")

      assert String.starts_with?(icon1, "hero-")
      assert String.starts_with?(icon2, "hero-")
    end
  end
end
