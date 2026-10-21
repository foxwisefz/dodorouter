defmodule DodoRouter.Proxy.ResponsesRequest do
  @moduledoc """
  Translates Responses history only when a routing step needs the chat IR.
  Native Responses steps retain opaque items verbatim. Unrepresentable items
  refuse the step before its adapter can sanitize away their payload.
  """

  alias DodoRouter.Proxy.Fidelity

  def prepare(request, :responses), do: {:ok, request}

  def prepare(request, _format) do
    with {:ok, messages} <- convert_messages(request["messages"] || []),
         {:ok, tools} <- convert_tools(request["tools"]),
         {:ok, choice} <- convert_choice(request["tool_choice"]) do
      converted =
        request
        |> Map.put("messages", messages)
        |> put_if_present("tools", tools)
        |> put_if_present("tool_choice", choice)

      for field <- ~w(messages tools tool_choice), request[field] != converted[field] do
        Fidelity.record_body_rewrite(field, "Responses items translated to Chat Completions")
      end

      {:ok, converted}
    end
  end

  defp convert_messages(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case convert_item(item, "messages[#{index}]") do
        {:ok, %{"role" => "assistant", "tool_calls" => calls} = message}
        when :erlang.map_get("type", item) == "function_call" ->
          case acc do
            [%{"role" => "assistant"} = previous | rest] ->
              merged = Map.update(previous, "tool_calls", calls, &(&1 ++ calls))
              {:cont, {:ok, [merged | rest]}}

            _ ->
              {:cont, {:ok, [message | acc]}}
          end

        {:ok, message} ->
          {:cont, {:ok, [message | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp convert_item(
         %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => args},
         _path
       )
       when is_binary(id) and is_binary(name) and is_binary(args) do
    {:ok,
     %{
       "role" => "assistant",
       "content" => nil,
       "tool_calls" => [
         %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => args}}
       ]
     }}
  end

  defp convert_item(
         %{"type" => "function_call_output", "call_id" => id, "output" => output},
         path
       )
       when is_binary(id) do
    with {:ok, content} <- convert_content(output, path <> ".output", "tool") do
      {:ok, %{"role" => "tool", "tool_call_id" => id, "content" => content}}
    end
  end

  defp convert_item(%{"type" => type}, path) when type != "message",
    do: unsupported(path, type)

  defp convert_item(%{"role" => role, "content" => content} = item, path) do
    with {:ok, content} <- convert_content(content, path <> ".content", role) do
      {:ok, item |> Map.delete("type") |> Map.put("content", content)}
    end
  end

  defp convert_item(_item, path), do: unsupported(path, "malformed message")

  defp convert_content(content, _path, _role) when is_binary(content) or is_nil(content),
    do: {:ok, content}

  defp convert_content(parts, path, role) when is_list(parts) do
    with {:ok, parts} <-
           map_items(parts, path, fn part, part_path -> convert_part(part, part_path, role) end) do
      # All downstream adapters accept text strings; some wrap assistant
      # content as text when it accompanies tool calls, so passing an array
      # there would produce an invalid nested text value.
      if Enum.all?(parts, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
        {:ok, Enum.map_join(parts, "\n", & &1["text"])}
      else
        {:ok, parts}
      end
    end
  end

  defp convert_content(_content, path, _role), do: unsupported(path, "content")

  defp convert_part(%{"type" => type, "text" => text} = part, path, _role)
       when type in ["input_text", "output_text"] and is_binary(text) do
    extra =
      Map.drop(part, ~w(type text)) |> Enum.reject(fn {_k, v} -> v in [nil, []] end) |> Map.new()

    if map_size(extra) > 0 do
      Fidelity.record_dropped_body_fields(
        %{path => extra},
        :unsupported_by_format_conversion,
        "Responses text metadata has no Chat Completions equivalent"
      )
    end

    {:ok, %{"type" => "text", "text" => text}}
  end

  defp convert_part(%{"type" => "input_image", "image_url" => url} = part, _path, "user")
       when is_binary(url) do
    image = %{"url" => url} |> put_if_present("detail", part["detail"])
    {:ok, %{"type" => "image_url", "image_url" => image}}
  end

  defp convert_part(%{"type" => type} = part, _path, role)
       when type == "text" or (role == "user" and type in ["image_url", "file"]) or
              (role == "assistant" and type == "refusal"),
       do: {:ok, part}

  defp convert_part(part, path, _role), do: unsupported(path, item_type(part))

  defp convert_tools(nil), do: {:ok, nil}
  defp convert_tools(tools), do: map_items(tools, "tools", &convert_tool/2)

  defp convert_tool(%{"type" => "function", "function" => function} = tool, _path)
       when is_map(function), do: {:ok, tool}

  defp convert_tool(%{"type" => "function", "name" => name} = tool, _path)
       when is_binary(name) do
    {cache_control, function} = tool |> Map.delete("type") |> Map.pop("cache_control")

    {:ok,
     %{"type" => "function", "function" => function}
     |> put_if_present("cache_control", cache_control)}
  end

  defp convert_tool(tool, path), do: unsupported(path, item_type(tool))

  defp convert_choice(%{"type" => "function", "name" => name}) when is_binary(name),
    do: {:ok, %{"type" => "function", "function" => %{"name" => name}}}

  defp convert_choice(%{"type" => "function", "function" => function} = choice)
       when is_map(function), do: {:ok, choice}

  defp convert_choice(choice) when choice in [nil, "auto", "none", "required"], do: {:ok, choice}
  defp convert_choice(choice), do: unsupported("tool_choice", item_type(choice))

  defp map_items(items, path, fun) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case fun.(item, "#{path}[#{index}]") do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp map_items(_items, path, _fun), do: unsupported(path, "expected array")

  defp unsupported(path, type) do
    message =
      "Cannot translate Responses #{type} at #{path} for this route; use a Responses-format provider."

    {:error, :bad_request,
     %{
       status: 400,
       body: %{
         "error" => %{
           "type" => "invalid_request_error",
           "code" => "unsupported_responses_item",
           "param" => path,
           "message" => message
         }
       }
     }}
  end

  defp item_type(%{"type" => type}) when is_binary(type), do: type
  defp item_type(_), do: "unknown item"
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
