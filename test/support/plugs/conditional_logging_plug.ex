defmodule PlugTestHelpers.ConditionalLoggingPlug do
  use Plug.Builder

  plug(Plug.LoggerJSON,
    log: :debug,
    should_log_request_fn: &__MODULE__.should_log_request/1,
    should_log_response_fn: &__MODULE__.should_log_response/1
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:passthrough)

  defp passthrough(conn, _) do
    # Simulate different responses based on path
    cond do
      conn.request_path == "/api/nonexistent" ->
        Plug.Conn.send_resp(conn, 404, "Not Found")

      conn.request_path == "/internal/status" and conn.assigns[:force_error] ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")

      true ->
        Plug.Conn.send_resp(conn, 200, "Passthrough")
    end
  end

  def should_log_request(conn) do
    cond do
      # Skip health checks and monitoring endpoints
      conn.request_path in ["/health", "/metrics"] -> false
      # Skip successful OPTIONS requests
      conn.method == "OPTIONS" and conn.status < 400 -> false
      # Always log errors regardless of path
      conn.status >= 400 -> true
      # Skip internal endpoints that are successful
      String.starts_with?(conn.request_path, "/internal/") and conn.status < 300 -> false
      # Default: log everything else
      true -> true
    end
  end

  def should_log_response(conn) do
    cond do
      # Skip health checks and monitoring endpoints
      conn.request_path in ["/health", "/metrics"] -> false
      # Skip successful OPTIONS requests
      conn.method == "OPTIONS" and conn.status < 400 -> false
      # Always log errors regardless of path
      conn.status >= 400 -> true
      # Skip internal endpoints that are successful
      String.starts_with?(conn.request_path, "/internal/") and conn.status < 300 -> false
      # Default: log everything else
      true -> true
    end
  end
end
