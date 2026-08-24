defmodule DodoRouterWeb.OAuthTransportTest do
  use DodoRouterWeb.ConnCase

  alias DodoRouter.AuthZ

  # Production terminates TLS at Caddy and reaches the app over plain HTTP on
  # loopback, so attesto only ever sees `conn.scheme == :http` plus Caddy's
  # `x-forwarded-proto: https`. That header is honored solely for peers in
  # `trusted_proxies` — with the default `[]`, every OAuth endpoint refused
  # real HTTPS traffic with "the request must be made over TLS", which broke
  # RFC 7591 registration (and the token endpoint) for every MCP client.

  @registration_body %{
    "client_name" => "transport-test-client",
    "redirect_uris" => ["http://127.0.0.1:33418/callback"],
    "grant_types" => ["authorization_code"],
    "response_types" => ["code"],
    "token_endpoint_auth_method" => "none"
  }

  defp post_registration(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/oauth/register", Jason.encode!(@registration_body))
  end

  setup do
    # server_config/0 memoizes in :persistent_term; make sure this test reads
    # the app env as configured, not a config another test cached earlier.
    AuthZ.reset_config()
    on_exit(fn -> AuthZ.reset_config() end)
    :ok
  end

  test "registration succeeds from a trusted loopback proxy forwarding https", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> post_registration()

    assert %{"client_id" => _} = json_response(conn, 201)
  end

  test "plain HTTP with no forwarded scheme is still refused", %{conn: conn} do
    conn = post_registration(conn)

    assert %{"error_description" => "the request must be made over TLS"} =
             json_response(conn, 400)
  end

  test "the /mcp challenge advertises the configured https resource metadata URL", %{conn: conn} do
    # The WWW-Authenticate challenge is the first thing an MCP client ever
    # reads, and SDKs hard-reject a non-TLS resource_metadata URL before even
    # attempting registration. Behind the TLS-terminating edge the raw
    # conn.scheme is http, so the URL must be pinned to the configured
    # audience origin, never derived from the request.
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))

    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge =~
             ~s(resource_metadata="https://localhost/.well-known/oauth-protected-resource/mcp")
  end

  test "a forwarded scheme from an untrusted peer is still refused", %{conn: conn} do
    conn =
      %{conn | remote_ip: {203, 0, 113, 9}}
      |> put_req_header("x-forwarded-proto", "https")
      |> post_registration()

    assert %{"error_description" => "the request must be made over TLS"} =
             json_response(conn, 400)
  end
end
