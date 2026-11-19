defmodule DodoRouterWeb.Plugs.EndUserIdentity do
  @moduledoc """
  Consumes attribution headers before a proxy controller can forward or log them.
  """

  import Plug.Conn

  @id_header "x-dodo-user-id"
  @token_header "x-dodo-user-token"

  def init(opts), do: opts

  def call(conn, _opts) do
    ids = get_req_header(conn, @id_header)
    tokens = get_req_header(conn, @token_header)

    headers =
      Enum.reject(conn.req_headers, fn {name, _} -> name in [@id_header, @token_header] end)

    conn = %{conn | req_headers: headers}

    case identity(ids, tokens, conn.assigns.current_router.id) do
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

  defp identity([], [], _router_id), do: {:ok, nil}

  defp identity([value], [], _router_id) do
    id = String.trim(value)

    if valid?(id) and byte_size(id) <= 255 and not String.starts_with?(id, "hmac:") do
      {:ok, id}
    else
      {:error,
       "X-Dodo-User-Id must be a nonempty ID of up to 255 bytes without the reserved hmac: prefix."}
    end
  end

  defp identity([], [value], router_id) do
    token = String.trim(value)

    if valid?(token) do
      secret = DodoRouterWeb.Endpoint.config(:secret_key_base)
      key = :crypto.mac(:hmac, :sha256, secret, "dodo-end-user-v1:" <> router_id)
      digest = :crypto.mac(:hmac, :sha256, key, token)
      {:ok, "hmac:" <> Base.encode16(digest, case: :lower)}
    else
      {:error, "X-Dodo-User-Token must be nonempty text."}
    end
  end

  defp identity(_ids, _tokens, _router_id),
    do: {:error, "Send a single X-Dodo-User-Id or X-Dodo-User-Token header."}

  defp valid?(value),
    do: value != "" and String.valid?(value) and not String.match?(value, ~r/[[:cntrl:]]/u)
end
