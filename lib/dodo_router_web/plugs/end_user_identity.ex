defmodule DodoRouterWeb.Plugs.EndUserIdentity do
  @moduledoc """
  Consumes the user ID header before a proxy controller can forward or log them.
  """

  import Plug.Conn

  @id_header "x-dodo-user-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    ids = get_req_header(conn, @id_header)

    headers =
      Enum.reject(conn.req_headers, fn {name, _} -> name == @id_header end)

    conn = %{conn | req_headers: headers}

    case identity(ids) do
      {:ok, id} ->
        assign(conn, :end_user_id, id)

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: %{type: "invalid_request_error", message: message}})
        )
        |> halt()
    end
  end

  defp identity([]), do: {:ok, nil}

  defp identity([value]) do
    id = String.trim(value)

    if valid?(id) and byte_size(id) <= 255 do
      {:ok, id}
    else
      {:error,
       "X-Dodo-User-Id must be a nonempty ID of up to 255 bytes without control characters."}
    end
  end

  defp identity(_ids), do: {:error, "Send a single X-Dodo-User-Id header."}

  defp valid?(value),
    do: value != "" and String.valid?(value) and not String.match?(value, ~r/[[:cntrl:]]/u)
end
