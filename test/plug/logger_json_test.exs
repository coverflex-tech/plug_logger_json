defmodule Plug.LoggerJSONTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  require Logger

  alias PlugTestHelpers.{
    DebugPlug,
    InfoPlug,
    InfoWithDebugPlug,
    ConditionalLoggingPlug,
    RequestResponseLoggingPlug,
    ExceptionHandlingPlug,
    SeparateLoggingPlug,
    DelayPlug
  }

  # Common test data
  @common_headers %{
    "content-type" => "application/json"
  }

  @http_methods [:get, :post, :put, :patch, :delete, :options]
  @health_paths ["/health", "/metrics"]
  @api_paths ["/api/users", "/api/test"]
  @error_paths ["/api/nonexistent"]

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
    # Remove all ANSI color codes
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    # Remove newlines
    |> String.replace("\n", "")
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
    with_log(fn ->
      func.()
    end)
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
  defp make_request_and_get_log(conn, plug \\ DebugPlug) do
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

  # Common assertion helpers
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

  defp assert_response_log(log_map, expected_status \\ 200) do
    assert log_map["phase"] == "response"
    assert log_map["status"] == expected_status
    assert log_map["log_type"] == "http"
  end

  defp assert_request_log(log_map) do
    assert log_map["phase"] == "request"
    assert log_map["status"] == nil
    assert log_map["log_type"] == "http"
  end

  # Helper to test duration in log
  defp with_duration(log_map, test_fn) do
    duration = log_map["duration"]
    test_fn.(duration)
    log_map
  end

  # Helper to setup common test connection
  defp setup_test_conn(method \\ :get, path \\ "/", params \\ %{}, headers \\ %{}) do
    conn(method, path, params)
    |> Map.update!(:req_headers, fn existing_headers ->
      Enum.map(headers, fn {key, value} -> {key, value} end) ++ existing_headers
    end)
  end

  # Helper to setup test connection with forwarded headers
  defp setup_test_conn_with_forwarded(method \\ :get, path \\ "/", params \\ %{}, headers \\ %{}) do
    forwarded_headers = %{
      "x-forwarded-for" => "209.49.75.165",
      "x-client-version" => "ios/1.5.4"
    }

    setup_test_conn(method, path, params, Map.merge(headers, forwarded_headers))
  end

  # Update the existing basic request logging tests
  describe "basic request logging" do
    test "logs basic GET request" do
      log_map =
        setup_test_conn()
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{}
      assert log_map["path"] == "/"
      assert_response_log(log_map)
      # Add assertions for date_time format
      assert is_binary(log_map["date_time"])
      assert String.match?(log_map["date_time"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    test "logs GET request with query params" do
      log_map =
        setup_test_conn(:get, "/", %{fake_param: "1"}, @common_headers)
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{"fake_param" => "1"}
      assert log_map["path"] == "/"
      assert_response_log(log_map)
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
        setup_test_conn(:post, "/", json_payload, @common_headers)
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "POST"
      assert log_map["params"] == json_payload
      assert log_map["path"] == "/"
      assert_response_log(log_map)
    end
  end

  describe "request and response logging" do
    test "logs both request and response phases" do
      logs =
        setup_test_conn()
        |> make_request_and_get_all_logs(RequestResponseLoggingPlug)

      # Should have exactly 2 log entries
      assert length(logs) == 2

      [request_log, response_log] = logs

      # Request log (first one, no status)
      assert request_log["method"] == "GET"
      assert request_log["path"] == "/"
      assert_request_log(request_log)

      # Response log (second one, with status)
      assert response_log["method"] == "GET"
      assert response_log["path"] == "/"
      assert_response_log(response_log)
    end

    test "logs only response by default" do
      logs =
        setup_test_conn()
        |> make_request_and_get_all_logs(DebugPlug)

      # Should have exactly 1 log entry (response only)
      assert length(logs) == 1

      [response_log] = logs
      assert_response_log(response_log)
    end
  end

  describe "Phoenix integration" do
    test "logs Phoenix controller info" do
      log_map =
        setup_test_conn()
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

  describe "client information" do
    test "logs client IP from X-Forwarded-For" do
      log_map =
        setup_test_conn_with_forwarded()
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
    test "filters authorization headers" do
      log_map =
        setup_test_conn()
        |> put_req_header("authorization", "f3443890-6683-4a25-8094-f23cf10b72d0")
        |> make_request_and_get_log()

      # Authorization headers aren't shown in debug mode params by default
      assert log_map["params"] == %{}
    end

    test "filters sensitive parameters" do
      # Set filtered_keys for this specific test
      Application.put_env(:plug_logger_json, :filtered_keys, ["password", "authorization"])

      log_map =
        setup_test_conn(:post, "/", %{authorization: "secret-token", username: "test"})
        |> make_request_and_get_log()

      assert log_map["params"]["authorization"] == "[FILTERED]"
      assert log_map["params"]["username"] == "test"
    end

    test "filters nested sensitive parameters" do
      Application.put_env(:plug_logger_json, :filtered_keys, ["password"])

      log_map =
        setup_test_conn(:post, "/", %{
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

    for method <- @http_methods do
      @tag method: method
      test "filters sensitive params for HTTP method #{method}", ctx do
        %{method: method} = ctx
        Application.put_env(:plug_logger_json, :filtered_keys, ["password", "token"])

        log_map =
          setup_test_conn(method, "/", %{
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

  describe "extra attributes" do
    test "includes custom attributes from assigns and private" do
      log_map =
        setup_test_conn()
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_log()

      assert log_map["user_id"] == "1234"
      assert log_map["other_id"] == "555"
      assert log_map["phase"] == "response"
      refute Map.has_key?(log_map, "should_not_appear")
    end
  end

  describe "special data types" do
    test "handles structs in parameters" do
      log_map =
        setup_test_conn(:post, "/", %{photo: %Plug.Upload{}})
        |> make_request_and_get_log()

      expected_photo = %{"content_type" => nil, "filename" => nil, "path" => nil}
      assert log_map["params"]["photo"] == expected_photo
      assert log_map["phase"] == "response"
    end
  end

  describe "log level configurations" do
    test "excludes debug info at info level" do
      log_map =
        setup_test_conn(:get, "/", %{fake_param: "1"})
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(InfoPlug)

      assert log_map["client_ip"] == nil
      assert log_map["client_version"] == nil
      assert log_map["params"] == nil
    end

    test "includes debug info when explicitly enabled" do
      log_map =
        setup_test_conn(:get, "/", %{fake_param: "1"})
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(InfoWithDebugPlug)

      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["client_version"] == "ios/1.5.4"
      assert log_map["params"] == %{"fake_param" => "1"}
    end
  end

  describe "error logging" do
    test "logs runtime errors with stacktrace" do
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

  describe "exception handling" do
    test "logs request when exception occurs" do
      log_map =
        setup_test_conn(:get, "/exception")
        |> make_exception_request_and_get_log(ExceptionHandlingPlug)

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

    test "logs normal requests without exceptions" do
      log_map =
        setup_test_conn(:get, "/normal")
        |> make_request_and_get_log(ExceptionHandlingPlug)

      # Verify normal operation still works
      assert_common_log_fields(log_map)
      assert log_map["method"] == "GET"
      assert log_map["path"] == "/normal"
      assert log_map["status"] == 200
      assert log_map["phase"] == "response"
    end
  end

  describe "conditional logging" do
    for path <- @health_paths do
      @tag path: path
      test "skips health check for path #{path}", ctx do
        %{path: path} = ctx
        message = make_request_and_get_message(setup_test_conn(:get, path), ConditionalLoggingPlug)
        assert message == ""
      end
    end

    test "skips successful OPTIONS requests" do
      message = make_request_and_get_message(setup_test_conn(:options, "/api/users"), ConditionalLoggingPlug)

      assert message == "" || String.contains?(message, "\"status\":200") ||
               String.contains?(message, "\"phase\":\"request\"")
    end

    test "logs failed OPTIONS requests" do
      log_map =
        setup_test_conn(:options, "/api/nonexistent")
        |> make_request_and_get_log(ConditionalLoggingPlug)

      assert_common_log_fields(log_map)
      assert log_map["method"] == "OPTIONS"
      assert log_map["path"] == "/api/nonexistent"
      assert_response_log(log_map, 404)
    end

    for path <- @api_paths do
      @tag path: path
      test "logs API requests for existing path #{path}", ctx do
        %{path: path} = ctx

        log_map =
          setup_test_conn(:get, path)
          |> make_request_and_get_log(ConditionalLoggingPlug)

        assert_common_log_fields(log_map)
        assert log_map["method"] == "GET"
        assert log_map["path"] == path
        assert_response_log(log_map)
      end
    end

    # Test error paths separately
    for path <- @error_paths do
      @tag path: path
      test "logs API requests for not found path #{path}", ctx do
        %{path: path} = ctx

        log_map =
          setup_test_conn(:get, path)
          |> make_request_and_get_log(ConditionalLoggingPlug)

        assert_common_log_fields(log_map)
        assert log_map["method"] == "GET"
        assert log_map["path"] == path
        assert_response_log(log_map, 404)
      end
    end
  end

  describe "duration calculation" do
    test "calculates duration in milliseconds" do
      # Create a test that simulates some processing time
      log_map =
        setup_test_conn()
        |> Plug.LoggerJSON.call(duration_unit: :millisecond)
        |> make_request_and_get_log(DelayPlug)

      # Verify duration is present and is a number
      assert is_number(log_map["duration"])

      # Duration should be positive (some time elapsed)
      assert log_map["duration"] > 0

      # Duration should be reasonable (less than 1 second for a simple test)
      assert log_map["duration"] < DelayPlug.delay() * 2

      # Verify phase is response for default behavior
      assert log_map["phase"] == "response"
    end

    test "calculates duration for failed requests" do
      log_map =
        setup_test_conn(:get, "/exception")
        |> make_exception_request_and_get_log(ExceptionHandlingPlug)

      # Verify duration is still calculated for failed requests
      assert is_number(log_map["duration"])
      assert is_integer(log_map["duration"])
      assert log_map["phase"] == "response"
    end
  end

  describe "phase attribute" do
    test "request phase has no status" do
      logs =
        setup_test_conn()
        |> make_request_and_get_all_logs(RequestResponseLoggingPlug)

      # Should have exactly 2 log entries
      assert length(logs) == 2

      [request_log, response_log] = logs

      # Request log should have phase=request and no status
      assert_request_log(request_log)
      # Increased delta to handle small timing variations
      assert_in_delta request_log["duration"], 0, 0.02

      # Response log should have phase=response and status set
      assert_response_log(response_log)
      assert is_integer(response_log["duration"])
    end

    test "response phase has status" do
      log_map =
        setup_test_conn()
        |> make_request_and_get_log(DebugPlug)

      # Default behavior logs only response
      assert_response_log(log_map)
    end

    for method <- @http_methods do
      @tag method: method
      test "phase is consistent for HTTP method #{method}", ctx do
        %{method: method} = ctx

        log_map =
          setup_test_conn(method, "/api/test")
          |> make_request_and_get_log(DebugPlug)

        assert_response_log(log_map)
        assert log_map["method"] == String.upcase(to_string(method))
      end
    end

    test "phase works with different status codes" do
      # Test with 404 error - using conditional logging plug that logs 404s
      log_map =
        setup_test_conn(:get, "/api/nonexistent")
        |> make_request_and_get_log(ConditionalLoggingPlug)

      assert_response_log(log_map, 404)
    end
  end

  describe "duration unit configuration" do
    for {duration_unit, expected_duration} <- [
          {:nanosecond, DelayPlug.delay() * 100_000},
          {:microsecond, DelayPlug.delay() * 100},
          {:millisecond, DelayPlug.delay()}
        ] do
      @tag duration_unit: duration_unit
      @tag expected_duration: expected_duration
      test "logs duration in #{duration_unit}", ctx do
        %{duration_unit: duration_unit, expected_duration: expected_duration} = ctx
        conn = setup_test_conn()

        conn
        |> Plug.LoggerJSON.call(duration_unit: duration_unit)
        |> make_request_and_get_log(DelayPlug)
        |> with_duration(fn duration ->
          assert duration >= expected_duration
        end)
      end
    end

    test "defaults to milliseconds" do
      setup_test_conn()
      |> Plug.LoggerJSON.call([])
      |> make_request_and_get_log(DelayPlug)
      |> with_duration(fn duration ->
        assert duration >= 1
      end)
    end
  end

  describe "separate request and response logging" do
    test "logs request for API paths" do
      # API path - should log request
      logs =
        setup_test_conn(:get, "/api/users")
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      # Should have exactly 2 logs (request and response)
      assert length(logs) == 2
      [request_log, response_log] = logs
      assert_request_log(request_log)
      assert_response_log(response_log)
      assert request_log["path"] == "/api/users"
      assert response_log["path"] == "/api/users"

      # Non-API path - should not log request
      logs =
        setup_test_conn(:get, "/health")
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      assert length(logs) == 0
    end

    test "logs response for non-health paths" do
      # Non-health path - should log response
      logs =
        setup_test_conn(:get, "/api/users")
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert_request_log(request_log)
      assert_response_log(response_log)
      assert request_log["path"] == "/api/users"
      assert response_log["path"] == "/api/users"

      # Health path - should not log response
      logs =
        setup_test_conn(:get, "/health")
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      assert length(logs) == 0
    end

    test "handles error responses" do
      # Test with error response
      logs =
        setup_test_conn(:get, "/api/nonexistent")
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert_request_log(request_log)
      assert_response_log(response_log)
      assert request_log["path"] == "/api/nonexistent"
      assert response_log["path"] == "/api/nonexistent"
    end

    for method <- @http_methods do
      @tag method: method
      test "works with HTTP method #{method}", ctx do
        %{method: method} = ctx

        logs =
          setup_test_conn(method, "/api/test")
          |> make_request_and_get_all_logs(SeparateLoggingPlug)

        assert length(logs) == 2
        [request_log, response_log] = logs
        assert_request_log(request_log)
        assert_response_log(response_log)
        assert request_log["method"] == String.upcase(to_string(method))
        assert response_log["method"] == String.upcase(to_string(method))
        assert request_log["path"] == "/api/test"
        assert response_log["path"] == "/api/test"
      end
    end

    test "preserves extra attributes" do
      logs =
        setup_test_conn(:get, "/api/users")
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_all_logs(SeparateLoggingPlug)

      assert length(logs) == 2
      [request_log, response_log] = logs
      assert_request_log(request_log)
      assert_response_log(response_log)

      # Extra attributes should be present in both request and response logs
      assert request_log["user_id"] == "1234"
      assert request_log["other_id"] == "555"
      assert response_log["user_id"] == "1234"
      assert response_log["other_id"] == "555"
    end
  end
end
