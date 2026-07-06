defmodule DodoRouterWeb.LayoutsTest do
  use DodoRouterWeb.ConnCase, async: true

  setup :register_and_log_in_user

  test "sidebar uses the same 'Logs' label on desktop and mobile nav", %{conn: conn} do
    html = conn |> get(~p"/routers") |> html_response(200)

    refute html =~ "Logzzz"
    # Desktop sidebar and mobile drawer must use the same label for /logs
    assert Regex.scan(~r/href="\/logs"[^>]*>.*?<\/a>/s, html)
           |> Enum.all?(&(&1 |> hd() =~ "Logs"))
  end
end
