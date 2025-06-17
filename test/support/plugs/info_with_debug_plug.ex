defmodule PlugTestHelpers.InfoWithDebugPlug do
  use Plug.Builder

  plug(Plug.LoggerJSON, log: :info, include_debug_logging: true)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:passthrough)

  defp passthrough(conn, _) do
    Plug.Conn.send_resp(conn, 200, "Passthrough")
  end
end
