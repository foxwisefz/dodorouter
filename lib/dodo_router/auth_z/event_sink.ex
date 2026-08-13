defmodule DodoRouter.AuthZ.EventSink do
  @moduledoc """
  Where authorization-server events go.

  Routed into the same `agent_api_calls` audit trail as everything else on the
  agent surface rather than a log file of its own: "a client registered itself
  and then a token was issued for it" belongs next to "that token then read
  these prompts", and two separate records nobody joins is how that story gets
  lost.
  """

  @behaviour AttestoPhoenix.EventSink

  require Logger

  alias DodoRouter.Agents

  @impl true
  def on_event(event) do
    name = event_name(event)

    Agents.record_call(%{
      principal_kind: "oauth",
      principal_name: client_name(event),
      interface: "mcp",
      operation: "oauth/#{name}",
      outcome: outcome(name),
      scopes: scopes(event)
    })

    Logger.info("attesto event: #{name}")
    :ok
  end

  # AttestoPhoenix.Event carries `:name`. Matching the wrong key fell through to
  # inspect/1, which stuffed the entire struct into a varchar(255) column and
  # lost the audit row to a truncation error.
  defp event_name(%{name: name}) when is_atom(name) or is_binary(name), do: to_string(name)
  defp event_name(%{event: name}), do: to_string(name)
  defp event_name(%{"event" => name}), do: to_string(name)
  defp event_name(event) when is_atom(event), do: to_string(event)
  defp event_name(event), do: inspect(event)

  # Failures are the rows worth finding later — a run of refused token requests
  # is either a misconfigured client or someone probing.
  defp outcome(name) do
    cond do
      String.contains?(name, "denied") or String.contains?(name, "rejected") -> "denied"
      String.contains?(name, "error") or String.contains?(name, "failed") -> "error"
      true -> "ok"
    end
  end

  defp client_name(%{client: %{client_name: name}}) when is_binary(name), do: name
  defp client_name(%{client_id: id}) when is_binary(id), do: id
  defp client_name(_event), do: nil

  defp scopes(%{scope: scope}) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp scopes(%{scope: scopes}) when is_list(scopes), do: scopes
  defp scopes(%{scopes: scopes}) when is_list(scopes), do: scopes
  defp scopes(_event), do: []
end
