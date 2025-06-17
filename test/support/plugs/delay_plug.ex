defmodule PlugTestHelpers.DelayPlug do
  use Plug.Builder

  #  plug(Plug.LoggerJSON, log: :info)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:passthrough)

  def delay() do
    10
  end

  defp passthrough(conn, _) do
    Process.sleep(delay())
    Plug.Conn.send_resp(conn, 200, "Passthrough")
  end
end
