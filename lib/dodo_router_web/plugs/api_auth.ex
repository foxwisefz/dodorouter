defmodule DodoRouterWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates API requests via Bearer token.

  Extracts the API key from the Authorization header and looks up the router.
  Sets `conn.assigns.current_router` on success.
  """

  import Plug.Conn
  alias DodoRouter.Routers

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, api_key} <- extract_bearer_token(conn),
         %{} = router <- get_router(conn, api_key) do
      assign(conn, :current_router, router)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: %{message: "Invalid API key", type: "authentication_error"}})
        )
        |> halt()
    end
  end

  # For new /r/:router_slug/v1 endpoints, verify slug matches API key
  defp get_router(%{path_params: %{"router_slug" => slug}} = _conn, api_key) do
    case Routers.get_router_by_api_key(api_key) do
      %{slug: ^slug} = router -> router
      _ -> nil
    end
  end

  # For legacy /v1 endpoints, just look up by API key
  defp get_router(_conn, api_key) do
    Routers.get_router_by_api_key(api_key)
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] when is_binary(key) and byte_size(key) > 0 -> {:ok, String.trim(key)}
          _ -> :error
        end
    end
  end
end
