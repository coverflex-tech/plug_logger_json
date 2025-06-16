defmodule PlugTestHelpers.ExceptionHandlingPlug do
  use Plug.Builder

  plug(Plug.LoggerJSON, log: :debug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:handle_request)

  defp handle_request(conn, _) do
    try do
      if conn.request_path == "/exception" do
        raise RuntimeError, "Something went wrong in the controller"
      else
        Plug.Conn.send_resp(conn, 200, "OK")
      end
    rescue
      _error ->
        # Set status to 500 and manually log the request
        # We need to prevent the normal before_send callback from running
        # by removing the before_send callbacks
        conn = conn |> put_status(500)

        # Clear before_send callbacks to avoid double logging
        private = %{conn.private | before_send: []}
        conn = %Plug.Conn{conn | private: private}

        # Manually log the request
        Plug.LoggerJSON.log_request(conn)

        send_resp(conn, 500, "Internal Server Error")
    end
  end
end
