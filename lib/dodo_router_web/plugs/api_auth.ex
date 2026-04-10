defmodule DodoRouterWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates API requests via Bearer token.

  Extracts the API key from the Authorization header and looks up the project.
  Sets `conn.assigns.current_project` on success.
  """

  import Plug.Conn
  alias DodoRouter.Projects

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, api_key} <- extract_bearer_token(conn),
         %{} = project <- Projects.get_project_by_api_key(api_key) do
      assign(conn, :current_project, project)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{message: "Invalid API key", type: "authentication_error"}}))
        |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
