defmodule Plug.LoggerJSONTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  require Logger

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
      should_log_fn: &__MODULE__.should_log_request/1
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
  end

  # A simpler plug that uses try/catch instead of Plug.ErrorHandler
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

  # Setup to preserve original config and restore it after tests
  setup do
    original_config = Application.get_env(:plug_logger_json, :filtered_keys)

    on_exit(fn ->
      if original_config do
        Application.put_env(:plug_logger_json, :filtered_keys, original_config)
      else
        Application.delete_env(:plug_logger_json, :filtered_keys)
      end
    end)

    %{original_config: original_config}
  end

  # Test helpers
  defp remove_colors(message) do
    message
    |> String.replace("\e[36m", "")
    |> String.replace("\e[31m", "")
    |> String.replace("\e[22m", "")
    |> String.replace("\n\e[0m", "")
    |> String.replace("{\"requ", "{\"requ")
  end

  defp call(conn, plug) do
    get_log(fn -> plug.call(conn, []) end)
  end

  defp call_with_exception(conn, plug) do
    get_log(fn ->
      try do
        plug.call(conn, [])
      catch
        # Catch any errors and return the conn
        _, _ -> conn
      end
    end)
  end

  defp get_log(func) do
    data =
      capture_log(fn ->
        Process.put(:get_log, func.())
        Logger.flush()
      end)

    {Process.get(:get_log), data}
  end

  # Helper to parse potentially multiple JSON lines
  defp parse_log_lines(message) do
    message
    |> remove_colors()
    |> String.trim()
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  # New helper functions for better readability
  defp make_request_and_get_log(conn, plug \\ MyDebugPlug) do
    {_conn, message} = call(conn, plug)

    case parse_log_lines(message) do
      [log_map] -> log_map
      # Take the first log if there are multiple
      [log_map | _] -> log_map
      [] -> raise "No log output captured"
    end
  end

  defp make_request_and_get_message(conn, plug) do
    {_conn, message} = call(conn, plug)
    message
  end

  defp make_exception_request_and_get_log(conn, plug) do
    {_conn, message} = call_with_exception(conn, plug)

    case parse_log_lines(message) do
      [log_map] -> log_map
      # Take the first log if there are multiple
      [log_map | _] -> log_map
      [] -> raise "No log output captured for exception test"
    end
  end

  defp assert_common_log_fields(log_map) do
    assert log_map["date_time"]
    assert log_map["duration"]
    assert log_map["log_type"] == "http"
  end

  defp assert_default_values(log_map) do
    assert log_map["api_version"] == "N/A"
    assert log_map["client_ip"] == "N/A"
    assert log_map["client_version"] == "N/A"
    assert log_map["handler"] == "N/A"
    assert log_map["request_id"] == nil
  end

  describe "basic request logging" do
    test "logs GET request with no parameters or headers" do
      log_map =
        conn(:get, "/")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{}
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end

    test "logs GET request with query parameters and headers" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("authorization", "f3443890-6683-4a25-8094-f23cf10b72d0")
        |> put_req_header("content-type", "application/json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{"fake_param" => "1"}
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end

    test "logs POST request with JSON body" do
      json_payload = %{
        "reaction" => %{
          "reaction" => "other",
          "track_id" => "7550",
          "type" => "emoji",
          "user_id" => "a2e684ee-2e5f-4e4d-879a-bb253908eef3"
        }
      }

      log_map =
        conn(:post, "/", Jason.encode!(json_payload))
        |> put_req_header("content-type", "application/json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "POST"
      assert log_map["params"] == json_payload
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end
  end

  describe "Phoenix integration" do
    test "logs handler information when Phoenix controller is present" do
      log_map =
        conn(:get, "/")
        |> put_private(:phoenix_controller, Plug.LoggerJSONTest)
        |> put_private(:phoenix_action, :show)
        |> put_private(:phoenix_format, "json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert log_map["handler"] == "Elixir.Plug.LoggerJSONTest#show"
      assert log_map["method"] == "GET"
      assert log_map["status"] == 200
    end
  end

  describe "client information extraction" do
    test "extracts client IP from X-Forwarded-For header" do
      log_map =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_private(:phoenix_controller, Plug.LoggerJSONTest)
        |> put_private(:phoenix_action, :show)
        |> put_private(:phoenix_format, "json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["handler"] == "Elixir.Plug.LoggerJSONTest#show"
    end
  end

  describe "parameter filtering" do
    test "does not expose authorization headers in params" do
      log_map =
        conn(:get, "/")
        |> put_req_header("authorization", "f3443890-6683-4a25-8094-f23cf10b72d0")
        |> make_request_and_get_log()

      # Authorization headers aren't shown in debug mode params by default
      assert log_map["params"] == %{}
    end

    test "filters sensitive parameters" do
      # Set filtered_keys for this specific test
      Application.put_env(:plug_logger_json, :filtered_keys, ["password", "authorization"])

      log_map =
        conn(:post, "/", authorization: "secret-token", username: "test")
        |> make_request_and_get_log()

      assert log_map["params"]["authorization"] == "[FILTERED]"
      assert log_map["params"]["username"] == "test"
    end

    test "filters nested sensitive parameters" do
      Application.put_env(:plug_logger_json, :filtered_keys, ["password"])

      log_map =
        conn(:post, "/", %{user: %{password: "secret", username: "me"}})
        |> make_request_and_get_log()

      user_params = log_map["params"]["user"]
      assert user_params["password"] == "[FILTERED]"
      assert user_params["username"] == "me"
    end
  end

  describe "extra attributes" do
    test "includes custom attributes from assigns and private data" do
      log_map =
        conn(:get, "/")
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_log()

      assert log_map["user_id"] == "1234"
      assert log_map["other_id"] == "555"
      refute Map.has_key?(log_map, "should_not_appear")
    end
  end

  describe "special data types handling" do
    test "handles structs in parameters" do
      log_map =
        conn(:post, "/", %{photo: %Plug.Upload{}})
        |> make_request_and_get_log()

      expected_photo = %{"content_type" => nil, "filename" => nil, "path" => nil}
      assert log_map["params"]["photo"] == expected_photo
    end
  end

  describe "log level configurations" do
    test "excludes debug information when log level is info" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(MyInfoPlug)

      assert log_map["client_ip"] == nil
      assert log_map["client_version"] == nil
      assert log_map["params"] == nil
    end

    test "includes debug information when explicitly enabled for info level" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(MyInfoPlugWithIncludeDebugLogging)

      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["client_version"] == "ios/1.5.4"
      assert log_map["params"] == %{"fake_param" => "1"}
    end
  end

  describe "error logging" do
    test "logs runtime errors with stacktrace information" do
      stacktrace = [
        {Plug.LoggerJSONTest, :call, 2, [file: ~c"lib/test.ex", line: 10]},
        {Plug.Adapters.Cowboy.Handler, :upgrade, 4, [file: ~c"lib/plug/adapters/cowboy/handler.ex", line: 15]}
      ]

      message =
        capture_log(fn ->
          Plug.LoggerJSON.log_error(:error, %RuntimeError{message: "oops"}, stacktrace)
        end)

      log_map = message |> remove_colors() |> Jason.decode!()

      assert log_map["log_type"] == "error"
      assert log_map["message"] =~ "** (RuntimeError) oops"
      assert log_map["message"] =~ "lib/test.ex:10: Plug.LoggerJSONTest.call/2"
      assert log_map["request_id"] == nil
    end
  end

  describe "exception handling" do
    test "logs request even when an exception is raised in the controller (simple approach)" do
      log_map =
        conn(:get, "/exception")
        |> make_exception_request_and_get_log(MySimpleExceptionPlug)

      # Verify that the request was logged despite the exception
      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/exception"
      assert log_map["status"] == 500
      assert log_map["client_ip"] == "N/A"
      assert log_map["client_version"] == "N/A"
      assert log_map["params"] == %{}
    end

    test "logs normal requests without exceptions in exception-handling plug" do
      log_map =
        conn(:get, "/normal")
        |> make_request_and_get_log(MySimpleExceptionPlug)

      # Verify normal operation still works
      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/normal"
      assert log_map["status"] == 200
    end
  end

  describe "conditional logging with should_log_fn" do
    test "does not log requests to health check paths" do
      message = make_request_and_get_message(conn(:get, "/health"), MyPlugWithConditionalLogging)
      assert message == ""
    end

    test "does not log requests to metrics endpoints" do
      message = make_request_and_get_message(conn(:get, "/metrics"), MyPlugWithConditionalLogging)
      assert message == ""
    end

    test "does not log successful OPTIONS requests" do
      message = make_request_and_get_message(conn(:options, "/api/users"), MyPlugWithConditionalLogging)
      assert message == ""
    end

    test "logs failed OPTIONS requests" do
      log_map =
        conn(:options, "/api/nonexistent")
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "OPTIONS"
      assert log_map["path"] == "/api/nonexistent"
      assert log_map["status"] == 404
    end

    test "does not log successful requests to internal paths" do
      message = make_request_and_get_message(conn(:get, "/internal/status"), MyPlugWithConditionalLogging)
      assert message == ""
    end

    test "logs failed requests to internal paths" do
      log_map =
        conn(:get, "/internal/status")
        |> assign(:force_error, true)
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/internal/status"
      assert log_map["status"] == 500
    end

    test "logs requests to regular API paths" do
      log_map =
        conn(:get, "/api/users")
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/api/users"
      assert log_map["status"] == 200
    end

    test "logs when should_log_fn is not provided" do
      # Test default behavior (should log everything)
      log_map =
        conn(:get, "/health")
        |> make_request_and_get_log(MyDebugPlug)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/health"
      assert log_map["status"] == 200
    end
  end

  describe "duration calculation" do
    test "calculates duration in milliseconds with proper precision" do
      # Create a test that simulates some processing time
      log_map =
        conn(:get, "/")
        |> make_request_and_get_log()

      # Verify duration is present and is a number
      assert is_number(log_map["duration"])

      # Duration should be positive (some time elapsed)
      assert log_map["duration"] > 0

      # Duration should be reasonable (less than 1 second for a simple test)
      assert log_map["duration"] < 1000

      # Verify it's rounded to 3 decimal places by checking it can be parsed as expected
      duration_str = Float.to_string(log_map["duration"])

      decimal_places =
        case String.split(duration_str, ".") do
          # No decimal places
          [_integer] -> 0
          [_integer, decimal] -> String.length(decimal)
        end

      # Should have at most 3 decimal places
      assert decimal_places <= 3
    end

    test "duration is calculated correctly with simulated delay" do
      # Test with a plug that introduces a small delay
      defmodule DelayedPlug do
        use Plug.Builder

        plug(Plug.LoggerJSON, log: :debug)
        plug(:add_delay)
        plug(:passthrough)

        defp add_delay(conn, _) do
          # Small delay to ensure measurable duration
          # 500ms delay
          :timer.sleep(500)
          conn
        end

        defp passthrough(conn, _) do
          Plug.Conn.send_resp(conn, 200, "OK")
        end
      end

      log_map =
        conn(:get, "/")
        |> make_request_and_get_log(DelayedPlug)

      # Duration should be at least 500ms due to our delay
      assert log_map["duration"] >= 500.0

      # But shouldn't be too much longer (allowing for test execution overhead)
      assert log_map["duration"] < 502
    end

    test "duration is present even when request fails" do
      log_map =
        conn(:get, "/exception")
        |> make_exception_request_and_get_log(MySimpleExceptionPlug)

      # Verify duration is still calculated for failed requests
      assert is_number(log_map["duration"])
      assert log_map["duration"] > 0
    end
  end

  describe "duration unit configuration" do
    test "logs duration in nanoseconds when duration_unit is :nanoseconds" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call(duration_unit: :nanoseconds)
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Duration should be an integer in nanoseconds
        assert is_integer(duration)
        # Should be much larger than microseconds (multiplied by 1000)
        assert duration > 1000
      end)
    end

    test "logs duration in microseconds when duration_unit is :microseconds" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call(duration_unit: :microseconds)
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Duration should be an integer in microseconds
        assert is_integer(duration)
        # Should be a reasonable value (greater than 0)
        assert duration > 0
      end)
    end

    test "logs duration in milliseconds when duration_unit is :milliseconds" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call(duration_unit: :milliseconds)
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Duration should be a float in milliseconds
        assert is_float(duration)
        # Should be a reasonable value
        assert duration > 0.0
      end)
    end

    test "defaults to milliseconds when duration_unit is not specified" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call([])
        |> send_resp(200, "")
      end)
      # Add this line to remove ANSI color codes
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Should default to float milliseconds
        assert is_float(duration)
        assert duration > 0.0
      end)
    end

    test "defaults to milliseconds when duration_unit is invalid" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call(duration_unit: :invalid_unit)
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Should fallback to float milliseconds
        assert is_float(duration)
        assert duration > 0.0
      end)
    end

    test "duration precision is maintained for milliseconds" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call(duration_unit: :milliseconds)
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Should be a float
        assert is_float(duration)

        # Convert to string to check decimal places
        duration_str = Float.to_string(duration)

        # Should have at most 3 decimal places (due to Float.round(x, 3))
        case String.split(duration_str, ".") do
          [_integer_part, decimal_part] ->
            assert String.length(decimal_part) <= 3

          [_integer_part] ->
            # No decimal part is also valid
            :ok
        end
      end)
    end

    test "duration units produce different value types" do
      # Test nanoseconds
      nano_duration =
        capture_log(fn ->
          conn(:get, "/")
          |> Plug.LoggerJSON.call(duration_unit: :nanoseconds)
          |> send_resp(200, "")
        end)
        |> remove_colors()
        |> decode_log_line()
        |> Map.get("duration")

      # Test microseconds
      micro_duration =
        capture_log(fn ->
          conn(:get, "/")
          |> Plug.LoggerJSON.call(duration_unit: :microseconds)
          |> send_resp(200, "")
        end)
        |> remove_colors()
        |> decode_log_line()
        |> Map.get("duration")

      # Test milliseconds
      milli_duration =
        capture_log(fn ->
          conn(:get, "/")
          |> Plug.LoggerJSON.call(duration_unit: :milliseconds)
          |> send_resp(200, "")
        end)
        |> remove_colors()
        |> decode_log_line()
        |> Map.get("duration")

      # Verify types
      assert is_integer(nano_duration)
      assert is_integer(micro_duration)
      assert is_float(milli_duration)

      # Verify relative magnitudes (nanoseconds should be largest)
      assert nano_duration > micro_duration
      assert micro_duration > trunc(milli_duration)
    end

    defp decode_log_line(log_output) do
      log_output
      |> String.trim()
      |> String.split("\n")
      |> List.last()
      |> Jason.decode!()
    end

    defp with_duration(log_map, test_fn) do
      duration = Map.get(log_map, "duration")
      assert duration != nil, "Duration should be present in log"
      test_fn.(duration)
      log_map
    end
  end
end
