defmodule PlugTestHelpers do
  defmodule MyDebugPlug do
    use Plug.Builder

    plug(Plug.LoggerJSON, log: :debug, extra_attributes_fn: &__MODULE__.extra_attributes/1)

    plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason
    )

    plug(:passthrough)

    defp passthrough(conn, _) do
      Plug.Conn.send_resp(conn, 200, "Passthrough")
    end

    def extra_attributes(conn) do
      map = %{
        "user_id" => get_in(conn.assigns, [:user, :user_id]),
        "other_id" => get_in(conn.private, [:private_resource, :id]),
        "should_not_appear" => conn.private[:does_not_exist]
      }

      map
      |> Enum.filter(fn {_key, value} -> value !== nil end)
      |> Enum.into(%{})
    end
  end

  defmodule MyInfoPlug do
    use Plug.Builder

    plug(Plug.LoggerJSON, log: :info)

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

  defmodule MyInfoPlugWithIncludeDebugLogging do
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

  defmodule MyPlugWithConditionalLogging do
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

  defmodule MyPlugWithRequestAndResponseLogging do
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

  defmodule MySimpleExceptionPlug do
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

  defmodule MyPlugWithSeparateLogging do
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
end
