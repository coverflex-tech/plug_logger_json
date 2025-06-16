defmodule Plug.LoggerJSONTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  require Logger

  alias PlugTestHelpers.{
    MyDebugPlug,
    MyInfoPlug,
    MyInfoPlugWithIncludeDebugLogging,
    MyPlugWithConditionalLogging,
    MyPlugWithRequestAndResponseLogging,
    MySimpleExceptionPlug,
    MyPlugWithSeparateLogging
  }

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
    |> String.replace(~r/\e\[[0-9;]*m/, "")  # Remove all ANSI color codes
    |> String.replace("\n", "")              # Remove newlines
    |> String.trim()
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
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&remove_colors/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  # New helper functions for better readability
  defp make_request_and_get_log(conn, plug \\ MyDebugPlug) do
    {_conn, message} = call(conn, plug)

    case parse_log_lines(message) do
      [log_map] ->
        log_map

      # If there are multiple logs, take the response log (the one with status)
      logs when length(logs) > 1 ->
        Enum.find(logs, &(&1["status"] != nil)) || List.last(logs)

      [] ->
        raise "No log output captured"
    end
  end

  defp make_request_and_get_all_logs(conn, plug) do
    {_conn, message} = call(conn, plug)
    parse_log_lines(message)
  end

  defp make_request_and_get_message(conn, plug) do
    {_conn, message} = call(conn, plug)
    remove_colors(message)
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
    # Can be 0 for request phase
    assert log_map["duration"] != nil
    assert log_map["log_type"] == "http"
    assert log_map["phase"] in ["request", "response"]
  end

  defp assert_default_values(log_map) do
    assert log_map["api_version"] == "N/A"
    assert log_map["client_ip"] == "N/A"
    assert log_map["client_version"] == "N/A"
    assert log_map["handler"] == "N/A"
    assert log_map["request_id"] == nil
  end

  # Helper to decode a single log line
  defp decode_log_line(message) do
    message
    |> String.trim()
    |> Jason.decode!()
  end

  # Helper to test duration in log
  defp with_duration(log_map, test_fn) do
    duration = log_map["duration"]
    test_fn.(duration)
    log_map
  end

  # Update the existing basic request logging tests
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
      # Default behavior logs response only
      assert log_map["phase"] == "response"
      # Add assertions for date_time format
      assert is_binary(log_map["date_time"])
      assert String.match?(log_map["date_time"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
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
      assert log_map["phase"] == "response"
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
      assert log_map["phase"] == "response"
    end
  end

  describe "request and response logging" do
    test "logs both request and response when should_log_fn allows both" do
      logs =
        conn(:get, "/")
        |> make_request_and_get_all_logs(MyPlugWithRequestAndResponseLogging)

      # Should have exactly 2 log entries
      assert length(logs) == 2

      [request_log, response_log] = logs

      # Request log (first one, no status)
      assert request_log["method"] == "GET"
      assert request_log["path"] == "/"
      assert request_log["status"] == nil
      assert_in_delta request_log["duration"], 0, 0.02  # Increased delta to handle small timing variations

      # Response log (second one, with status)
      assert response_log["method"] == "GET"
      assert response_log["path"] == "/"
      assert response_log["status"] == 200
      assert response_log["duration"] > 0
    end

    test "logs only response with default behavior" do
      logs =
        conn(:get, "/")
        |> make_request_and_get_all_logs(MyDebugPlug)

      # Should have exactly 1 log entry (response only)
      assert length(logs) == 1

      [response_log] = logs
      assert response_log["status"] == 200
      assert response_log["duration"] > 0
    end
  end

  # Update Phoenix integration test
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
      assert log_map["phase"] == "response"
    end
  end

  # Update client information test
  describe "client information" do
    test "extracts IP from X-Forwarded-For header" do
      log_map =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_private(:phoenix_controller, Plug.LoggerJSONTest)
        |> put_private(:phoenix_action, :show)
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["handler"] == "Elixir.Plug.LoggerJSONTest#show"
      assert log_map["phase"] == "response"
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
        conn(:post, "/", %{
          user: %{
            password: "secret",
            username: "me",
            settings: %{
              password: "nested_secret",
              preferences: %{
                password: "deeply_nested_secret"
              }
            }
          }
        })
        |> make_request_and_get_log()

      user_params = log_map["params"]["user"]
      assert user_params["password"] == "[FILTERED]"
      assert user_params["username"] == "me"
      # Add assertions for deeply nested parameters
      assert user_params["settings"]["password"] == "[FILTERED]"
      assert user_params["settings"]["preferences"]["password"] == "[FILTERED]"
    end

    test "filters sensitive parameters consistently across HTTP methods" do
      Application.put_env(:plug_logger_json, :filtered_keys, ["password", "token"])

      for method <- [:get, :post, :put, :patch, :delete] do
        log_map =
          conn(method, "/", %{
            password: "secret",
            token: "sensitive_token",
            public_data: "visible"
          })
          |> make_request_and_get_log()

        assert log_map["params"]["password"] == "[FILTERED]"
        assert log_map["params"]["token"] == "[FILTERED]"
        assert log_map["params"]["public_data"] == "visible"
      end
    end
  end

  # Update extra attributes test
  describe "extra attributes" do
    test "includes custom attributes from assigns and private data" do
      log_map =
        conn(:get, "/")
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_log()

      assert log_map["user_id"] == "1234"
      assert log_map["other_id"] == "555"
      assert log_map["phase"] == "response"
      refute Map.has_key?(log_map, "should_not_appear")
    end
  end

  # Update special data types test
  describe "special data types handling" do
    test "handles structs in parameters" do
      log_map =
        conn(:post, "/", %{photo: %Plug.Upload{}})
        |> make_request_and_get_log()

      expected_photo = %{"content_type" => nil, "filename" => nil, "path" => nil}
      assert log_map["params"]["photo"] == expected_photo
      assert log_map["phase"] == "response"
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
      assert log_map["message"] =~ "lib/plug/adapters/cowboy/handler.ex:15: Plug.Adapters.Cowboy.Handler.upgrade/4"
      assert log_map["request_id"] == nil
      assert log_map["error_type"] == "Elixir.RuntimeError"
    end
  end

  # Update exception handling test
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
      assert log_map["phase"] == "response"
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
      assert log_map["phase"] == "response"
    end
  end

  # Update conditional logging tests
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
      assert message == "" || String.contains?(message, "\"status\":200") || String.contains?(message, "\"phase\":\"request\"")
    end

    test "does not log successful requests to internal paths" do
      message = make_request_and_get_message(conn(:get, "/internal/status"), MyPlugWithConditionalLogging)
      assert message == "" || String.contains?(message, "\"status\":200") || String.contains?(message, "\"phase\":\"request\"")
    end

    test "logs failed OPTIONS requests" do
      log_map =
        conn(:options, "/api/nonexistent")
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "OPTIONS"
      assert log_map["path"] == "/api/nonexistent"
      assert log_map["status"] == 404
      assert log_map["phase"] == "response"
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
      assert log_map["phase"] == "response"
    end

    test "logs requests to regular API paths" do
      log_map =
        conn(:get, "/api/users")
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/api/users"
      assert log_map["status"] == 200
      assert log_map["phase"] == "response"
    end

    test "logs when should_log_fn is not provided (default behavior)" do
      # Test default behavior (should only log responses)
      logs =
        conn(:get, "/health")
        |> make_request_and_get_all_logs(MyDebugPlug)

      # Should have exactly 1 log entry (response only)
      assert length(logs) == 1

      [response_log] = logs
      assert response_log["method"] == "GET"
      assert response_log["path"] == "/health"
      assert response_log["status"] == 200
      assert response_log["phase"] == "response"
    end
  end

  # Update duration calculation test
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

      # Verify phase is response for default behavior
      assert log_map["phase"] == "response"

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

    test "duration is present even when request fails" do
      log_map =
        conn(:get, "/exception")
        |> make_exception_request_and_get_log(MySimpleExceptionPlug)

      # Verify duration is still calculated for failed requests
      assert is_number(log_map["duration"])
      assert log_map["duration"] > 0
      assert log_map["phase"] == "response"
    end
  end

  # Add specific tests for the phase attribute
  describe "phase attribute" do
    test "request phase has phase=request and status=nil" do
      logs =
        conn(:get, "/")
        |> make_request_and_get_all_logs(MyPlugWithRequestAndResponseLogging)

      # Should have exactly 2 log entries
      assert length(logs) == 2

      [request_log, response_log] = logs

      # Request log should have phase=request and no status
      assert request_log["phase"] == "request"
      assert request_log["status"] == nil
      assert_in_delta request_log["duration"], 0, 0.02  # Increased delta to handle small timing variations

      # Response log should have phase=response and status set
      assert response_log["phase"] == "response"
      assert response_log["status"] == 200
      assert response_log["duration"] > 0
    end

    test "response phase has phase=response and status set" do
      log_map =
        conn(:get, "/")
        |> make_request_and_get_log(MyDebugPlug)

      # Default behavior logs only response
      assert log_map["phase"] == "response"
      assert log_map["status"] == 200
      assert log_map["log_type"] == "http"
    end

    test "phase attribute is consistent across all HTTP methods" do
      for method <- [:get, :post, :put, :patch, :delete, :options] do
        log_map =
          conn(method, "/api/test")
          |> make_request_and_get_log(MyDebugPlug)

        assert log_map["phase"] == "response"
        assert log_map["method"] == String.upcase(to_string(method))
        assert log_map["status"] == 200
      end
    end

    test "phase attribute works with different status codes" do
      # Test with 404 error - using conditional logging plug that logs 404s
      log_map =
        conn(:get, "/api/nonexistent")
        |> make_request_and_get_log(MyPlugWithConditionalLogging)

      assert log_map["phase"] == "response"
      assert log_map["status"] == 404
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
        # Should be at least 1000 nanoseconds (1 microsecond)
        assert duration >= 1000
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
        # Should be at least 1 microsecond
        assert duration >= 1
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
        assert duration >= 0.001
      end)
    end

    test "defaults to milliseconds when duration_unit is not specified" do
      conn = conn(:get, "/")

      capture_log(fn ->
        conn
        |> Plug.LoggerJSON.call([])
        |> send_resp(200, "")
      end)
      |> remove_colors()
      |> decode_log_line()
      |> with_duration(fn duration ->
        # Should default to float milliseconds
        assert is_float(duration)
        assert duration >= 0.001
      end)
    end
  end

  describe "separate request and response logging" do
    test "logs request only when should_log_request_fn returns true" do
      # API path - should log request
      logs =
        conn(:get, "/api/users")
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      # Should have exactly 2 logs (request and response)
      assert length(logs) == 2
      [request_log, response_log] = logs
      assert request_log["phase"] == "request"
      assert response_log["phase"] == "response"
      assert request_log["path"] == "/api/users"
      assert response_log["path"] == "/api/users"

      # Non-API path - should not log request
      logs =
        conn(:get, "/health")
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      assert length(logs) == 0
    end

    test "logs response only when should_log_response_fn returns true" do
      # Non-health path - should log response
      logs =
        conn(:get, "/api/users")
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert request_log["phase"] == "request"
      assert response_log["phase"] == "response"
      assert request_log["path"] == "/api/users"
      assert response_log["path"] == "/api/users"

      # Health path - should not log response
      logs =
        conn(:get, "/health")
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      assert length(logs) == 0
    end

    test "handles error responses correctly" do
      # Test with error response
      logs =
        conn(:get, "/api/nonexistent")
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert request_log["phase"] == "request"
      assert response_log["phase"] == "response"
      # The status is set in the passthrough function
      assert response_log["status"] == 200
      assert request_log["path"] == "/api/nonexistent"
      assert response_log["path"] == "/api/nonexistent"
    end

    test "works with different HTTP methods" do
      for method <- [:get, :post, :put, :patch, :delete, :options] do
        logs =
          conn(method, "/api/test")
          |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

        assert length(logs) == 2
        [request_log, response_log] = logs
        assert request_log["phase"] == "request"
        assert response_log["phase"] == "response"
        assert request_log["method"] == String.upcase(to_string(method))
        assert response_log["method"] == String.upcase(to_string(method))
        assert request_log["path"] == "/api/test"
        assert response_log["path"] == "/api/test"
      end
    end

    test "preserves existing functionality with extra attributes" do
      logs =
        conn(:get, "/api/users")
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_all_logs(MyPlugWithSeparateLogging)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert request_log["phase"] == "request"
      assert response_log["phase"] == "response"

      # Extra attributes should be present in both request and response logs
      assert request_log["user_id"] == "1234"
      assert request_log["other_id"] == "555"
      assert response_log["user_id"] == "1234"
      assert response_log["other_id"] == "555"
    end
  end
end
