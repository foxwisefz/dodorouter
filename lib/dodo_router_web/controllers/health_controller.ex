defmodule DodoRouterWeb.HealthController do
  use DodoRouterWeb, :controller

  def index(conn, _params) do
    cond do
      # Shutting down - tell LB to stop sending traffic
      DodoRouter.ShutdownListener.shutting_down?() ->
        conn
        |> put_status(503)
        |> json(%{status: "draining"})

      # Check DB connection
      db_healthy?() ->
        json(conn, %{status: "ok"})

      true ->
        conn
        |> put_status(503)
        |> json(%{status: "error", reason: "database_unavailable"})
    end
  end

  defp db_healthy? do
    case Ecto.Adapters.SQL.query(DodoRouter.Repo, "SELECT 1") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
