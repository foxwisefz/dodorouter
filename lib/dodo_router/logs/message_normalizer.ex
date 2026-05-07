defmodule DodoRouter.Logs.MessageNormalizer do
  @moduledoc """
  Normalize the wire-format `messages` JSON we capture from LLM API requests
  and responses into a uniform shape the UI can render.

  Used by both the private log detail view and the public sharing pages, so
  it lives in the context layer rather than the LiveView.
  """

  @doc """
  Parse a stored request body (JSON string or already-decoded map) and return
  `{normalized_messages, other_request_params}`.
  """
  def parse_request_body(nil), do: {[], %{}}

  def parse_request_body(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> parse_request_body(decoded)
      _ -> {[], %{}}
    end
  end

  def parse_request_body(%{"messages" => messages} = decoded) when is_list(messages) do
    {Enum.map(messages, &normalize_message/1), Map.drop(decoded, ["messages"])}
  end

  def parse_request_body(_), do: {[], %{}}

  @doc """
  Parse a stored response body and return the assistant-side normalized message,
  or nil if the body is missing or malformed.
  """
  def parse_response_body(nil), do: nil

  def parse_response_body(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> parse_response_body(decoded)
      _ -> nil
    end
  end

  def parse_response_body(%{"choices" => [%{"message" => msg} | _]}), do: normalize_message(msg)
  def parse_response_body(%{"choices" => [%{"delta" => msg} | _]}), do: normalize_message(msg)
  def parse_response_body(_), do: nil

  @doc """
  Normalize a single message map into `%{role, content, tool_calls, tool_call_id, name, reasoning_content}`.
  """
  def normalize_message(%{"role" => role, "content" => content} = msg) do
    %{
      role: role,
      content: normalize_content(content),
      tool_calls: msg["tool_calls"],
      tool_call_id: msg["tool_call_id"],
      name: msg["name"],
      reasoning_content: msg["reasoning_content"]
    }
  end

  def normalize_message(%{"content" => content} = msg) do
    %{
      role: msg["role"] || "assistant",
      content: normalize_content(content),
      tool_calls: msg["tool_calls"],
      tool_call_id: msg["tool_call_id"],
      name: msg["name"],
      reasoning_content: msg["reasoning_content"]
    }
  end

  def normalize_message(msg) do
    %{
      role: "unknown",
      content: inspect(msg),
      tool_calls: nil,
      tool_call_id: nil,
      name: nil,
      reasoning_content: nil
    }
  end

  @doc """
  Normalize message content into a single string. Handles raw strings,
  multimodal content blocks, and unexpected shapes.
  """
  def normalize_content(nil), do: ""
  def normalize_content(str) when is_binary(str), do: str

  def normalize_content(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n\n")
  end

  def normalize_content(other), do: inspect(other)
end
