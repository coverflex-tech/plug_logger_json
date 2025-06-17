defmodule PlugTestHelpers.SeparateLoggingPlug do
  use Plug.Builder

  plug(Plug.LoggerJSON,
    log: :debug,
    should_log_request_fn: &__MODULE__.should_log_request/1,
    should_log_response_fn: &__MODULE__.should_log_response/1,
    extra_attributes_fn: &__MODULE__.extra_attributes/1
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:passthrough)

  defp passthrough(conn, _) do
    Plug.Conn.send_resp(conn, 200, "Passthrough")
  end

  def should_log_request(conn) do
    # Only log requests for API paths
    String.starts_with?(conn.request_path, "/api/")
  end

  def should_log_response(conn) do
    # Log all responses except health checks
    conn.request_path not in ["/health", "/metrics"]
  end

  def extra_attributes(conn) do
    map = %{
      "user_id" => get_in(conn.assigns, [:user, :user_id]),
      "other_id" => get_in(conn.private, [:private_resource, :id])
    }

    map
    |> Enum.filter(fn {_key, value} -> value != nil end)
    |> Enum.into(%{})
  end
end
