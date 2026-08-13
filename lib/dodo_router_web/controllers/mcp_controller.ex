defmodule DodoRouterWeb.MCPController do
  @moduledoc """
  Model Context Protocol endpoint, revision `2026-07-28`.

  Hand-rolled because no Elixir MCP *server* SDK speaks this revision yet — and
  that is affordable only because the revision made the protocol core stateless:
  no `initialize` handshake, no `Mcp-Session-Id`, no standalone GET stream. One
  POST carrying one JSON-RPC message, answered inline.

  Responses are plain `application/json` rather than SSE. The spec allows either,
  and the one operation slow enough to want progress events — running a
  benchmark — is already asynchronous behind `run_eval` + `get_eval` polling, so
  a stream would carry nothing.

  What the revision *does* require, and what the surprises are:

    * Every POST mirrors `method` and (for `tools/call`) `params.name` into
      `Mcp-Method` / `Mcp-Name` headers, and the server **must** reject a
      mismatch with `-32020`. The point is that a load balancer routing on the
      header and a server executing the body can never disagree.
    * `Mcp-Name` may arrive base64-wrapped as `=?base64?…?=`, and must be
      decoded before comparison.
    * `Origin` must be validated — this endpoint is reachable from a browser,
      and without the check a page on any origin could drive it via DNS
      rebinding.
    * GET and DELETE are `405`; they were the old session/stream verbs.
  """

  use DodoRouterWeb, :controller

  alias DodoRouter.MCP.Tools
  alias DodoRouterWeb.AgentApi
  alias DodoRouterWeb.Plugs.AgentAudit

  @protocol_version "2026-07-28"
  @supported_versions [@protocol_version]

  @server_info %{name: "dodo-router", title: "DodoRouter", version: "1"}

  # JSON-RPC and MCP error codes used here.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @internal_error -32_603
  @header_mismatch -32_020

  def create(conn, _params) do
    with :ok <- check_origin(conn),
         {:ok, message} <- body(conn),
         :ok <- check_protocol_version(conn, message),
         :ok <- check_mirrored_headers(conn, message) do
      dispatch(conn, message)
    else
      {:error, status, code, message, data} -> rpc_error(conn, status, nil, code, message, data)
    end
  end

  # The old transport's verbs. A modern-only server answers 405 rather than
  # pretending to offer a session or a standalone stream.
  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> rpc_error(
      405,
      nil,
      @invalid_request,
      "This MCP endpoint accepts POST only. Sessions and standalone GET streams were removed in #{@protocol_version}."
    )
  end

  ## Dispatch

  # A notification has no id and gets 202 with no body, per the transport spec.
  defp dispatch(conn, %{"method" => method, "id" => nil} = message),
    do: dispatch_notification(conn, method, message)

  defp dispatch(conn, %{"method" => method} = message) when not is_map_key(message, "id"),
    do: dispatch_notification(conn, method, message)

  defp dispatch(conn, %{"method" => "tools/list", "id" => id}) do
    principal = AgentApi.principal(conn)

    conn
    |> AgentAudit.annotate(operation: "tools/list")
    |> rpc_result(id, %{tools: Tools.list(principal)})
  end

  defp dispatch(conn, %{"method" => "tools/call", "id" => id} = message) do
    principal = AgentApi.principal(conn)
    params = message["params"] || %{}
    name = params["name"]
    args = params["arguments"] || %{}

    conn = AgentAudit.annotate(conn, operation: "tools/call", tool: name)

    case safely(fn -> Tools.call(principal, name, args) end) do
      {:ok, payload, meta} ->
        conn
        |> AgentAudit.annotate(Map.to_list(meta))
        |> rpc_result(id, tool_result(payload))

      {:error, message} ->
        # A failed tool is a *successful* JSON-RPC call carrying isError, not a
        # protocol error — the model is meant to read the message and adapt,
        # which it cannot do if the transport swallows it.
        rpc_result(conn, id, %{
          content: [%{type: "text", text: message}],
          isError: true
        })
    end
  end

  defp dispatch(conn, %{"method" => "ping", "id" => id}), do: rpc_result(conn, id, %{})

  defp dispatch(conn, %{"method" => method, "id" => id}) do
    rpc_error(
      conn,
      404,
      id,
      @method_not_found,
      "This server does not implement #{method}.",
      %{implemented: ["tools/list", "tools/call", "ping"]}
    )
  end

  defp dispatch(conn, _message),
    do: rpc_error(conn, 400, nil, @invalid_request, "Not a JSON-RPC request or notification.")

  defp dispatch_notification(conn, _method, _message) do
    # Nothing to do for any notification this revision defines, but it must be
    # accepted rather than answered.
    conn |> AgentAudit.annotate(operation: "notification") |> send_resp(202, "")
  end

  ## Validation

  # The endpoint is browser-reachable, so an absent Origin (a normal API client)
  # is fine while a present, foreign one is not.
  #
  # Checked against a configured list, not `Endpoint.url()` alone: the app is
  # reachable on more than one origin (plain http for the dashboard, TLS on
  # another port for OAuth, since attesto requires an https issuer), and
  # comparing against a single canonical URL rejects the very origin the OAuth
  # flow runs on.
  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if origin in allowed_origins() do
          :ok
        else
          {:error, 403, @invalid_request, "Origin #{origin} is not allowed for this endpoint.",
           nil}
        end
    end
  end

  defp allowed_origins do
    configured = Application.get_env(:dodo_router, :mcp_allowed_origins, [])
    Enum.uniq([DodoRouterWeb.Endpoint.url() | configured])
  end

  defp body(conn) do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method} = message when is_binary(method) ->
        {:ok, message}

      %{"jsonrpc" => version} ->
        {:error, 400, @invalid_request, "jsonrpc must be \"2.0\", got #{inspect(version)}.", nil}

      %Plug.Conn.Unfetched{} ->
        {:error, 400, @parse_error, "Request body could not be parsed as JSON.", nil}

      _ ->
        {:error, 400, @invalid_request, "Body must be a JSON-RPC request or notification.", nil}
    end
  end

  defp check_protocol_version(conn, message) do
    header = header(conn, "mcp-protocol-version")
    in_body = get_in(message, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"])

    cond do
      is_nil(header) ->
        {:error, 400, @header_mismatch,
         "The MCP-Protocol-Version header is required from #{@protocol_version}.", nil}

      not is_nil(in_body) and in_body != header ->
        {:error, 400, @header_mismatch,
         "MCP-Protocol-Version header (#{header}) does not match params._meta (#{in_body}).", nil}

      header not in @supported_versions ->
        {:error, 400, @invalid_request, "Unsupported protocol version #{header}.",
         %{supported: @supported_versions, requested: header}}

      true ->
        :ok
    end
  end

  # The header/body agreement rule. Without it an intermediary routing on
  # `Mcp-Name` and a server executing `params.name` could act on different tools
  # for the same request.
  defp check_mirrored_headers(conn, message) do
    with :ok <- match_header(conn, "mcp-method", message["method"], "Mcp-Method", "method") do
      case message["method"] do
        "tools/call" ->
          name = get_in(message, ["params", "name"])
          match_header(conn, "mcp-name", name, "Mcp-Name", "params.name")

        _other ->
          :ok
      end
    end
  end

  defp match_header(conn, header_name, expected, label, body_path) do
    case header(conn, header_name) do
      nil ->
        {:error, 400, @header_mismatch,
         "The #{label} header is required, mirroring #{body_path}.", nil}

      value ->
        if decode_sentinel(value) == expected do
          :ok
        else
          {:error, 400, @header_mismatch,
           "#{label} header (#{value}) does not match #{body_path} (#{inspect(expected)}).", nil}
        end
    end
  end

  # Values that cannot ride in an ASCII header arrive wrapped; the comparison
  # has to happen on the decoded value or a legitimate unicode tool name reads
  # as a mismatch.
  defp decode_sentinel("=?base64?" <> rest) do
    case String.split(rest, "?=", parts: 2) do
      [encoded, ""] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> "=?base64?" <> rest
        end

      _ ->
        "=?base64?" <> rest
    end
  end

  defp decode_sentinel(value), do: value

  ## Responses

  defp tool_result(payload) do
    %{
      # Text content is what every client can render; the same object rides
      # structuredContent for clients that prefer to parse rather than re-parse.
      content: [%{type: "text", text: Jason.encode!(payload, pretty: true)}],
      structuredContent: payload,
      isError: false
    }
  end

  defp rpc_result(conn, id, result) do
    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> json(%{jsonrpc: "2.0", id: id, result: Map.put_new(result, :serverInfo, @server_info)})
  end

  defp rpc_error(conn, status, id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error

    conn
    |> put_resp_header("mcp-protocol-version", @protocol_version)
    |> put_status(status)
    |> json(%{jsonrpc: "2.0", id: id, error: error})
  end

  # A crashing tool must still produce a JSON-RPC reply: an MCP client that
  # receives a bare 500 has no way to tell the model what went wrong.
  defp safely(fun) do
    fun.()
  rescue
    exception ->
      require Logger
      Logger.error("MCP tool crashed: #{Exception.format(:error, exception, __STACKTRACE__)}")
      {:error, "That tool failed: #{Exception.message(exception)}"}
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> String.trim(value)
      [] -> nil
    end
  end

  # Unused today but kept honest: the internal-error code belongs to the set
  # this module owns.
  @doc false
  def internal_error_code, do: @internal_error
end
