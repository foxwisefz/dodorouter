defmodule DodoRouterWeb.Components.ChartsCallTypeTest do
  use ExUnit.Case, async: true

  import DodoRouterWeb.Components.Charts

  describe "call_type_name/1" do
    test "one name per stored value, wherever it is rendered" do
      # The logs list said "Chat", the detail sidebar "Completion", and two
      # other views "chat" — three names for one value reads as three things.
      assert call_type_name("completion") == "Chat"
      assert call_type_name("tool_call") == "Tool call"
      assert call_type_name("tool_enabled_completion") == "Chat + tools"
    end

    test "an unrecorded or unknown type still renders something" do
      assert call_type_name(nil) == "Chat"
      assert call_type_name("something_new") == "something_new"
    end
  end
end
