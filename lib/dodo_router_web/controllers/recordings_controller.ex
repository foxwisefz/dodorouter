defmodule DodoRouterWeb.RecordingsController do
  use DodoRouterWeb, :controller

  alias DodoRouter.Recordings

  def start(conn, params) do
    router = conn.assigns.current_router
    name = Map.get(params, "name")

    case Recordings.start_recording(router, %{name: name}) do
      {:ok, recording} ->
        conn
        |> put_status(201)
        |> json(format_recording(recording))

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{
          error: %{message: "Failed to start recording", details: format_errors(changeset)}
        })
    end
  end

  def active(conn, _params) do
    router = conn.assigns.current_router

    case Recordings.get_active_recording(router) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: %{message: "No active recording", type: "not_found"}})

      recording ->
        json(conn, format_recording(recording))
    end
  end

  def stop(conn, _params) do
    router = conn.assigns.current_router

    case Recordings.stop_recording(router) do
      {:ok, recording} ->
        json(conn, format_recording(recording))

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{message: "No active recording", type: "not_found"}})
    end
  end

  defp format_recording(recording) do
    %{
      id: recording.id,
      name: recording.name,
      status: recording.status,
      started_at: recording.started_at,
      stopped_at: recording.stopped_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
