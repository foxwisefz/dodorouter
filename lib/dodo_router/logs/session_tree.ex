defmodule DodoRouter.Logs.SessionTree do
  @moduledoc """
  Build a branching tree from a list of logs in the same session.

  Every LLM API call replays the full prior conversation as the `messages`
  array, so two logs in a session necessarily share a prefix. This module
  collapses that shared prefix and exposes the divergence points as branches.

  The output is a tree of nodes:

      %Node{
        message: normalized_message | nil,  # nil only at the root
        logs: [log, ...],                   # logs whose conversation ENDS here
        children: [%Node{}, ...]            # divergence points
      }

  A leaf is reached when no log has a longer prefix than this turn.
  """

  alias DodoRouter.Logs.MessageNormalizer

  defmodule Node do
    @moduledoc false
    defstruct [:message, :depth, logs: [], children: []]
  end

  @doc """
  Build a tree from a list of logs. Each log is read for its full message
  history (request messages + response message, if any).

  The `kind` field on each tree leaf entry tells you whether a particular
  message was a `:request` (replayed prefix) or `:response` (terminal turn).
  """
  def build(logs) when is_list(logs) do
    paths = Enum.map(logs, &log_to_path/1)
    build_node(paths, nil, 0)
  end

  defp build_node(paths_with_logs, message, depth) do
    {leaves, deeper} =
      Enum.split_with(paths_with_logs, fn {path, _log} -> path == [] end)

    grouped =
      deeper
      |> Enum.group_by(
        fn {[next | _], _log} -> message_key(next) end,
        fn {[next | rest], log} -> {rest, log, next} end
      )

    children =
      grouped
      |> Enum.map(fn {_key, items} ->
        # All items share the same head message (`next`); take it from the first.
        [{_, _, child_msg} | _] = items
        next_paths = Enum.map(items, fn {rest, log, _} -> {rest, log} end)
        build_node(next_paths, child_msg, depth + 1)
      end)
      |> Enum.sort_by(& &1.depth)

    %Node{
      message: message,
      depth: depth,
      logs: Enum.map(leaves, fn {_path, log} -> log end),
      children: children
    }
  end

  # Convert a log into a list of normalized messages representing its full
  # conversation: request messages followed by the assistant response (if any).
  defp log_to_path(log) do
    body = preferred_request_body(log)
    {req_messages, _params} = MessageNormalizer.parse_request_body(body)

    response = MessageNormalizer.parse_response_body(preferred_response_body(log))

    messages =
      if response, do: req_messages ++ [response], else: req_messages

    {messages, log}
  end

  defp preferred_request_body(%{request_body: body}), do: body

  defp preferred_response_body(%{response_body: body}), do: body

  # Tolerate non-deterministic IDs by hashing only on stable fields:
  # role, content text, and the names of any tool functions invoked.
  defp message_key(%{role: role, content: content, tool_calls: tool_calls}) do
    tool_names =
      case tool_calls do
        list when is_list(list) ->
          list
          |> Enum.map(fn tc ->
            get_in(tc, ["function", "name"]) || tc["name"] || ""
          end)
          |> Enum.sort()

        _ ->
          []
      end

    {role, content, tool_names}
  end

  @doc """
  Flatten a tree into a list of branches, each branch being a list of messages
  from root to a log node. Useful for the right-pane "selected branch" view.
  """
  def branches(%Node{} = root) do
    walk_branches(root, [])
  end

  defp walk_branches(%Node{message: message, logs: logs, children: children}, acc) do
    acc = if message, do: acc ++ [message], else: acc

    log_branches = Enum.map(logs, fn log -> %{log: log, messages: acc} end)
    child_branches = Enum.flat_map(children, &walk_branches(&1, acc))
    log_branches ++ child_branches
  end

  @doc """
  Find the branch containing a particular log id. Returns the list of messages
  from root to that log, or nil if the log isn't in the tree.
  """
  def find_branch(%Node{} = root, log_id) do
    Enum.find_value(branches(root), fn %{log: log, messages: messages} ->
      if log.id == log_id, do: messages
    end)
  end
end
