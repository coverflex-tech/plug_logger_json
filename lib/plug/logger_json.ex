defmodule Plug.LoggerJSON do
  @moduledoc """
  A plug for logging basic request information in the format:
  ```json
  {
    "api_version":     "N/A"
    "client_ip":       "23.235.46.37"
    "client_version":  "ios/1.6.7",
    "date_time":       "2016-05-31T18:00:13Z",
    "duration":        4.670,
    "handler":         "fronts#index"
    "log_type":        "http",
    "method":          "POST",
    "params":          {
                         "user": "jkelly",
                         "password": "[FILTERED]"
                       },
    "path":            "/",
    "request_id":      "d90jcl66vp09r8tke3utjsd1pjrg4ln8",
    "status":          "200"
  }
  ```

  To use it, just plug it into the desired module.
  `plug Plug.LoggerJSON, log: :debug`

  ## Options

  * `:log` - The log level at which this plug should log its request info.
    Default is `:info`.
  * `:duration_unit` - The unit for duration logging. Can be `:nanoseconds`,
    `:microseconds`, or `:milliseconds`. Default is `:milliseconds`.
  * `:extra_attributes_fn` - Function to call with `conn` to add additional
    fields to the requests. Default is `nil`. Please see "Extra Fields" section
    for more information.
  * `:should_log_request_fn` - Function to call with `conn` to determine if the request
    should be logged. Should return `true` to log or `false` to skip logging.
    Default is `nil` (no request logging). Please see "Conditional Logging" section
    for more information.
  * `:should_log_response_fn` - Function to call with `conn` to determine if the response
    should be logged. Should return `true` to log or `false` to skip logging.
    Default is `nil` (logs all responses). Please see "Conditional Logging" section
    for more information.

  ## Duration Units

  You can customize the unit used for duration logging:

        # Log duration in nanoseconds (as integer)
        plug Plug.LoggerJSON, duration_unit: :nanoseconds

        # Log duration in microseconds (as integer)
        plug Plug.LoggerJSON, duration_unit: :microseconds

        # Log duration in milliseconds (as float, rounded to 3 decimal places) - default
        plug Plug.LoggerJSON, duration_unit: :milliseconds

  ## Extra Fields

  Additional data can be logged alongside the request by specifying a function
  to call which returns a map:

        def extra_attributes(conn) do
          map = %{
            "user_id" => get_in(conn.assigns, [:user, :user_id]),
            "other_id" => get_in(conn.private, [:private_resource, :id]),
            "should_not_appear" => conn.private[:does_not_exist]
          }

          map
          |> Enum.filter(&(&1 !== nil))
          |> Enum.into(%{})
        end

        plug Plug.LoggerJSON, log: Logger.level,
                              extra_attributes_fn: &MyPlug.extra_attributes/1

  In this example, the `:user_id` is retrieved from `conn.assigns.user.user_id`
  and added to the log if it exists. In the example, any values that are `nil`
  are filtered from the map. It is a requirement that the value is
  serializable as JSON by the Jason library, otherwise an error will be raised
  when attempting to encode the value.

  ## Conditional Logging

  You can control whether requests and responses should be logged by providing separate
  functions for each phase:

        # Control request logging
        def should_log_request(conn) do
          # Only log requests for specific paths
          conn.request_path in ["/api", "/v1"]
        end

        # Control response logging
        def should_log_response(conn) do
          # Log all responses except health checks
          conn.request_path not in ["/health", "/metrics"]
        end

        plug Plug.LoggerJSON,
          log: :debug,
          should_log_request_fn: &MyPlug.should_log_request/1,
          should_log_response_fn: &MyPlug.should_log_response/1

  The functions have access to the complete connection struct, including request
  information (method, path, headers, params) and response information (status,
  response headers) after the request has been processed.

  You can also use anonymous functions for simple cases:

        plug Plug.LoggerJSON,
          log: :debug,
          should_log_request_fn: &(&1.request_path in ["/api", "/v1"]),
          should_log_response_fn: &(&1.request_path not in ["/health", "/metrics"])

  Or share common logic between both functions:

        defp should_log_path?(conn, allowed_paths) do
          conn.request_path in allowed_paths
        end

        def should_log_request(conn), do: should_log_path?(conn, ["/api", "/v1"])
        def should_log_response(conn), do: should_log_path?(conn, ["/api", "/v1", "/health"])
  """

  alias Plug.Conn

  require Logger

  @typedoc """
  Type for a plug option.
  """
  @type opt ::
          :log
          | :duration_unit
          | :extra_attributes_fn
          | :should_log_request_fn
          | :should_log_response_fn
          | {:log, atom()}
          | {:duration_unit, :nanoseconds | :microseconds | :milliseconds}
          | {:extra_attributes_fn, (Plug.Conn.t() -> map())}
          | {:should_log_request_fn, (Plug.Conn.t() -> boolean())}
          | {:should_log_response_fn, (Plug.Conn.t() -> boolean())}

  @typedoc """
  Type for a list of plug options.
  """
  @type opts :: list(opt)

  @typedoc """
  Type for a timestamp with `{mega_secs, secs, micro_secs}`.
  """
  @type os_timestamp :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts() | atom()) :: Plug.Conn.t()
  def call(conn, level_or_opts) when is_atom(level_or_opts) do
    call(conn, log: level_or_opts)
  end

  def call(conn, opts) do
    level = Keyword.get(opts, :log, :info)
    start = :os.timestamp()

    # Store logging info in conn private for access in exception handlers
    conn = Conn.put_private(conn, :plug_logger_json_opts, opts)
    conn = Conn.put_private(conn, :plug_logger_json_start, start)
    conn = Conn.put_private(conn, :plug_logger_json_level, level)

    # Log request phase if enabled
    if should_log_request?(conn, opts) do
      log(conn, level, start, opts)
    end

    # Register before_send callback for response phase
    Conn.register_before_send(conn, fn conn ->
      if should_log_response?(conn, opts) do
        # Mark that we're in the before_send callback
        conn = Conn.put_private(conn, :plug_logger_json_before_send, true)
        log(conn, level, start, opts)
      end

      conn
    end)
  end

  @doc """
  Logs a request manually. This is useful for logging requests in exception handlers
  where the normal before_send callback might not be called.
  """
  @spec log_request(Plug.Conn.t()) :: :ok
  def log_request(conn) do
    case conn.private do
      %{
        plug_logger_json_opts: opts,
        plug_logger_json_start: start,
        plug_logger_json_level: level
      } ->
        should_log = should_log_response?(conn, opts)

        if should_log do
          # Mark that we're in the response phase since this is being called directly
          conn = Conn.put_private(conn, :plug_logger_json_before_send, true)
          log(conn, level, start, opts)
        end

        :ok

      _ ->
        # No logging configuration found, skip
        :ok
    end
  end

  @spec should_log_request?(Plug.Conn.t(), opts()) :: boolean()
  defp should_log_request?(conn, opts) do
    case Keyword.get(opts, :should_log_request_fn) do
      fun when is_function(fun, 1) ->
        fun.(conn)

      _ ->
        # Default: no request logging
        false
    end
  end

  @spec should_log_response?(Plug.Conn.t(), opts()) :: boolean()
  defp should_log_response?(conn, opts) do
    case Keyword.get(opts, :should_log_response_fn) do
      fun when is_function(fun, 1) ->
        fun.(conn)

      _ ->
        # Default: log all responses
        true
    end
  end

  @spec log(Plug.Conn.t(), atom(), os_timestamp() | nil, opts()) :: :ok | no_return()
  def log(conn, level, start, opts \\ [])

  def log(conn, :error, start, opts), do: log(conn, :info, start, opts)
  def log(conn, :info, start, opts), do: log_message(conn, :info, start, opts)
  def log(conn, :warning, start, opts), do: log(conn, :debug, start, opts)

  @deprecated "use :warning instead"
  def log(conn, :warn, start, opts), do: log(conn, :debug, start, opts)

  def log(conn, :debug, start, opts) do
    log_message(conn, :info, start, Keyword.put_new(opts, :include_debug_logging, true))
  end

  @spec log_error(atom(), map(), list()) :: :ok
  def log_error(kind, reason, stacktrace) do
    _ =
      Logger.log(:error, fn ->
        %{
          "log_type" => "error",
          "error_type" => (Kernel.is_exception(reason) && reason.__struct__) || kind,
          "message" => Exception.format(kind, reason, stacktrace),
          "request_id" => Logger.metadata()[:request_id]
        }
        |> Jason.encode!()
      end)
  end

  @spec log_message(Plug.Conn.t(), atom(), os_timestamp() | nil, opts()) :: :ok
  defp log_message(conn, level, start, opts) do
    Logger.log(level, fn ->
      conn
      |> basic_logging(start, opts)
      |> Map.merge(debug_logging(conn, opts))
      |> Map.merge(phoenix_attributes(conn))
      |> Map.merge(extra_attributes(conn, opts))
      |> Jason.encode!()
    end)
  end

  @spec basic_logging(Plug.Conn.t(), os_timestamp() | nil, opts()) :: map()
  defp basic_logging(conn, start, opts) do
    stop = :os.timestamp()
    duration = if start, do: :timer.now_diff(stop, start), else: 0
    req_id = Logger.metadata()[:request_id]
    req_headers = format_map_list(conn.req_headers)

    # Determine phase based on whether we're in the before_send callback
    phase = if conn.private[:plug_logger_json_before_send], do: "response", else: "request"

    log_json = %{
      "api_version" => Map.get(req_headers, "accept", "N/A"),
      "date_time" => iso8601(:calendar.now_to_datetime(:os.timestamp())),
      "duration" => format_duration(duration, opts),
      "log_type" => "http",
      "phase" => phase,
      "method" => conn.method,
      "path" => conn.request_path,
      "request_id" => req_id,
      "status" => conn.status
    }

    Map.drop(log_json, Application.get_env(:plug_logger_json, :suppressed_keys, []))
  end

  @spec format_duration(non_neg_integer(), opts()) :: number()
  defp format_duration(duration_microseconds, opts) do
    duration_unit = Keyword.get(opts, :duration_unit, :millisecond)

    case duration_unit do
      unit when unit in [:second, :millisecond, :microsecond, :nanosecond] ->
        System.convert_time_unit(duration_microseconds, :microsecond, unit)

      invalid_unit ->
        Logger.warning("Invalid duration unit: #{inspect(invalid_unit)}. Using default unit: :millisecond")
        System.convert_time_unit(duration_microseconds, :microsecond, :millisecond)
    end
  end

  @spec extra_attributes(Plug.Conn.t(), opts()) :: map()
  defp extra_attributes(conn, opts) do
    case Keyword.get(opts, :extra_attributes_fn) do
      fun when is_function(fun, 1) -> fun.(conn)
      _ -> %{}
    end
  end

  @spec client_version(map()) :: String.t()
  defp client_version(headers) do
    headers
    |> Map.get("x-client-version", "N/A")
    |> case do
      "N/A" ->
        Map.get(headers, "user-agent", "N/A")

      accept_value ->
        accept_value
    end
  end

  @spec debug_logging(Plug.Conn.t(), opts()) :: map()
  defp debug_logging(conn, opts) do
    case Keyword.get(opts, :include_debug_logging) do
      true ->
        req_headers = format_map_list(conn.req_headers)

        %{
          "client_ip" => format_ip(Map.get(req_headers, "x-forwarded-for", "N/A")),
          "client_version" => client_version(req_headers),
          "params" => format_map_list(conn.params)
        }

      _ ->
        %{}
    end
  end

  @spec filter_values(map() | struct(), [binary()]) :: map()
  defp filter_values(%{__struct__: mod} = struct, filters) when is_atom(mod) do
    struct
    |> Map.from_struct()
    |> filter_values(filters)
  end

  @spec filter_values(map(), [binary()]) :: map()
  defp filter_values(%{} = map, filters) do
    Enum.into(map, %{}, fn {k, v} ->
      if is_binary(k) and k in filters do
        {k, "[FILTERED]"}
      else
        {k, filter_values(v, filters)}
      end
    end)
  end

  @spec filter_values(list(), [binary()]) :: list()
  defp filter_values(list, filters) when is_list(list) do
    Enum.map(list, &filter_values(&1, filters))
  end

  defp filter_values(other, _filters), do: format_value(other)

  @spec format_ip(String.t()) :: String.t()
  defp format_ip("N/A") do
    "N/A"
  end

  defp format_ip(x_forwarded_for) do
    hd(String.split(x_forwarded_for, ", "))
  end

  @spec format_map_list(Enumerable.t()) :: map()
  defp format_map_list(enumerable) do
    enumerable
    |> filter_values(Application.get_env(:plug_logger_json, :filtered_keys, []))
    |> Enum.into(%{})
  end

  defp format_value(value) when is_binary(value) do
    String.slice(value, 0..500)
  end

  defp format_value(value) do
    value
  end

  defp iso8601({{year, month, day}, {hour, minute, second}}) do
    zero_pad(year, 4) <>
      "-" <>
      zero_pad(month, 2) <>
      "-" <>
      zero_pad(day, 2) <> "T" <> zero_pad(hour, 2) <> ":" <> zero_pad(minute, 2) <> ":" <> zero_pad(second, 2) <> "Z"
  end

  @spec phoenix_attributes(map()) :: map()
  defp phoenix_attributes(%{private: %{phoenix_controller: controller, phoenix_action: action}}) do
    %{"handler" => "#{controller}##{action}"}
  end

  defp phoenix_attributes(_) do
    %{"handler" => "N/A"}
  end

  @spec zero_pad(1..3_000, non_neg_integer()) :: String.t()
  defp zero_pad(val, count) do
    num = Integer.to_string(val)
    :binary.copy("0", count - byte_size(num)) <> num
  end
end
