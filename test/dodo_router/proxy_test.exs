defmodule DodoRouter.ProxyTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Proxy

  describe "truncate_body/1" do
    test "handles large text content truncation" do
      # Use text with spaces so it doesn't match base64 pattern
      large_content = String.duplicate("hello world ", 6_000)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => large_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_text_truncated" in flags
      assert String.length(truncated["messages"] |> hd() |> Map.get("content")) < 60_000
    end

    test "handles base64 content truncation" do
      # Valid base64 string (length divisible by 4, only base64 chars)
      base64_content = String.duplicate("QUJD", 500)

      request = %{
        "messages" => [
          %{"role" => "user", "content" => base64_content}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert "request_base64_truncated" in flags
    end

    test "handles nil body" do
      {body, flags} = Proxy.truncate_body(nil)

      assert body == nil
      assert flags == []
    end

    test "leaves small content unchanged" do
      request = %{
        "messages" => [
          %{"role" => "user", "content" => "Hello world"}
        ]
      }

      {truncated, flags} = Proxy.truncate_body(request)

      assert flags == []
      assert truncated["messages"] |> hd() |> Map.get("content") == "Hello world"
    end
  end
end
