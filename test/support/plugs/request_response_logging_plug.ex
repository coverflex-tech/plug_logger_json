defmodule PlugTestHelpers.RequestResponseLoggingPlug do
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
    Plug.Conn.send_resp(conn, 200, "Passthrough")
  end

  # Always log requests
  def should_log_request(_conn), do: true

  # Always log responses
  def should_log_response(_conn), do: true
end
