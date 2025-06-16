# PlugLoggerJson
[![Hex pm](http://img.shields.io/hexpm/v/plug_logger_json.svg?style=flat)](https://hex.pm/packages/plug_logger_json)
[![Build Status](https://travis-ci.org/bleacherreport/plug_logger_json.svg?branch=master)](https://travis-ci.org/bleacherreport/plug_logger_json)
[![License](https://img.shields.io/badge/license-Apache%202-blue.svg)](https://github.com/bleacherreport/plug_logger_json/blob/master/LICENSE)

A comprehensive JSON logger Plug.

## Dependencies

* Plug
* Jason

## Elixir & Erlang Support

The support policy is to support the last 2 major versions of Erlang and the three last minor versions of Elixir.

## Installation

1. Add `plug_logger_json` to your list of dependencies in `mix.exs`:

   ```elixir
   def deps do
     [{:plug_logger_json, "~> 0.8.0"}]
   end
   ```

2. Ensure `plug_logger_json` is started before your application (Skip if using Elixir 1.4 or greater):

   ```elixir
   def application do
     [applications: [:plug_logger_json]]
   end
   ```

3. Replace `Plug.Logger` with `Plug.LoggerJSON, opts` in your plug pipeline (in `endpoint.ex` for Phoenix apps).  See "Configuration Options" for available `opts`.

## Configuration Options

The following options can be configured:

*   `:log` - Logger level (`Logger.level`). Default: `:info`
*   `:extra_attributes_fn` - Function to call to get extra attributes to log.  It should accept a `Plug.Conn` and return a map.  See "Extra Attributes". Default: `nil`
*   `:filtered_keys` - Keys to filter from params and headers. Default: `[]`
*   `:suppressed_keys` - Keys to suppress from the log. Default: `[]`
*   `:include_debug_logging` - Whether to include debug logging (client_ip, client_version, and params).  If not set, the defaults are used.  See "Log Verbosity". Default: `nil`
*   `:should_log_request_fn` - Function to determine if the request should be logged. See "Conditional Logging". Default: `nil`
*   `:should_log_response_fn` - Function to determine if the response should be logged. See "Conditional Logging". Default: `nil`
*   `:duration_unit` - The unit for duration logging. Can be `:nanoseconds`, `:microseconds`, or `:milliseconds`. Default: `:milliseconds`

Example:

```elixir
plug Plug.LoggerJSON,
  log: Logger.level,
  extra_attributes_fn: &MyPlug.extra_attributes/1,
  filtered_keys: ["password", "authorization"],
  suppressed_keys: ["api_version", "log_type"],
  include_debug_logging: true,
  should_log_request_fn: &MyPlug.should_log_request/1,
  should_log_response_fn: &MyPlug.should_log_response/1,
  duration_unit: :milliseconds
```

## Log Format

The log entries are in JSON format and include the following fields:

```json
{
  "api_version":     "N/A",
  "client_ip":       "23.235.46.37",
  "client_version":  "ios/1.6.7",
  "date_time":       "2016-05-31T18:00:13Z",
  "duration":        4.670,
  "handler":         "fronts#index",
  "log_type":        "http",
  "method":          "POST",
  "params":          {
    "user": "jkelly",
    "password": "[FILTERED]"
  },
  "path":            "/",
  "phase":           "request",
  "request_id":      "d90jcl66vp09r8tke3utjsd1pjrg4ln8",
  "status":          "200"
}
```

The `phase` field indicates whether the log entry represents a request or response:
* `"request"` - Log entry for the initial request
* `"response"` - Log entry for the final response

The `duration` field can be configured to use different units:
* `:nanoseconds` - Returns an integer value (e.g., `4670123`)
* `:microseconds` - Returns an integer value (e.g., `4670`)
* `:milliseconds` - Returns a float value rounded to 3 decimal places (e.g., `4.670`)

## Recommended Setup

### Configure `plug_logger_json`

Add to your `config/config.exs` or `config/env_name.exs` if you want to filter params or headers or suppress any logged keys:

```elixir
config :plug_logger_json,
  filtered_keys: ["password", "authorization"],
  suppressed_keys: ["api_version", "log_type"]
```

### Configure the logger (console)

In your `config/config.exs` or `config/env_name.exs`:

```elixir
config :logger, :console,
  format: "$message\n",
  level: :info, # You may want to make this an env variable to change verbosity of the logs
  metadata: [:request_id]
```

### Configure the logger (file)

Do the following:

* update deps in `mix.exs` with the following:

    ```elixir
    def deps do
     [{:logger_file_backend, "~> 0.0.10"}]
    end
    ```

* add to your `config/config.exs` or `config/env_name.exs`:

    ```elixir
    config :logger,
      format: "$message\n",
      backends: [{LoggerFileBackend, :log_file}, :console]

    config :logger, :log_file,
      format: "$message\n",
      level: :info,
      metadata: [:request_id],
      path: "log/my_pipeline.log"
    ```

* ensure you are using `Plug.Parsers` (Phoenix adds this to `endpoint.ex` by default) to parse params as well as request body:

    ```elixir
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason
    ```

## Error Logging

In `router.ex` of your Phoenix project or in your plug pipeline:

* add `require Logger`,
* add `use Plug.ErrorHandler`,
* add the following two private functions:

    ```elixir
    defp handle_errors(%Plug.Conn{status: 500} = conn, %{kind: kind, reason: reason, stack: stacktrace}) do
      Plug.LoggerJSON.log_error(kind, reason, stacktrace)
      send_resp(conn, 500, Jason.encode!(%{errors: %{detail: "Internal server error"}}))
    end

    defp handle_errors(_, _), do: nil
    ```

## Extra Attributes

Additional data can be logged alongside the request by specifying a function to call which returns a map:

```elixir
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

plug Plug.LoggerJSON,
  log: Logger.level(),
  extra_attributes_fn: &MyPlug.extra_attributes/1
```

In this example, the `:user_id` is retrieved from `conn.assigns.user.user_id` and added to the log if it exists. In the example, any values that are `nil` are filtered from the map. It is a requirement that the value is serializable as JSON by the Jason library, otherwise an error will be raised when attempting to encode the value.

## Log Verbosity

`LoggerJSON` plug supports two levels of logging:

  * `info` / `error` will log:

    * api_version,
    * date_time,
    * duration,
    * log_type,
    * method,
    * path,
    * request_id,
    * status

  * `warning` / `debug` will log everything from info and:

    * client_ip,
    * client_version,
    * params / request_body.

The above are default. It is possible to override them by setting a `include_debug_logging` option to:

  * `false` – means the extra debug fields (client_ip, client_version, and params) WILL NOT get logged.
  * `true` – means the extra fields WILL get logged.
  * Not setting this option will keep the defaults above.

Example:

```elixir
plug Plug.LoggerJSON,
  log: Logger.level,
  include_debug_logging: true
```

## Conditional Logging

You can control whether requests and responses should be logged by providing separate functions for each phase:

```elixir
defmodule MyApp.Plugs do
  def should_log_request(conn) do
    # Only log requests for specific paths
    conn.request_path in ["/api", "/v1"]
  end

  def should_log_response(conn) do
    # Log all responses except health checks
    conn.request_path not in ["/health", "/metrics"]
  end
end

plug Plug.LoggerJSON,
  log: :debug,
  should_log_request_fn: &MyApp.Plugs.should_log_request/1,
  should_log_response_fn: &MyApp.Plugs.should_log_response/1
```

The functions have access to the complete connection struct, including request information (method, path, headers, params) and response information (status, response headers) after the request has been processed.

You can also use anonymous functions for simple cases:

```elixir
plug Plug.LoggerJSON,
  log: :debug,
  should_log_request_fn: &(&1.request_path in ["/api", "/v1"]),
  should_log_response_fn: &(&1.request_path not in ["/health", "/metrics"])
```

Or share common logic between both functions:

```elixir
defp should_log_path?(conn, allowed_paths) do
  conn.request_path in allowed_paths
end

def should_log_request(conn), do: should_log_path?(conn, ["/api", "/v1"])
def should_log_response(conn), do: should_log_path?(conn, ["/api", "/v1", "/health"])
```

## Duration Units

You can customize the unit used for duration logging by setting the `:duration_unit` option:

```elixir
# Log duration in nanoseconds (as integer)
plug Plug.LoggerJSON, duration_unit: :nanoseconds

// nanoseconds
{"duration": 4670123, ...}

# Log duration in microseconds (as integer)
plug Plug.LoggerJSON, duration_unit: :microseconds

// microseconds  
{"duration": 4670, ...}

# Log duration in milliseconds (as float, rounded to 3 decimal places) - default
plug Plug.LoggerJSON, duration_unit: :milliseconds

// milliseconds
{"duration": 4.67, ...}
```

## Contributing

Before submitting your pull request, please run:

  * `mix credo --strict`,
  * `mix coveralls`,
  * `mix dialyzer`,
  *  update changelog.

Please squash your pull request's commits into a single commit with a message and detailed description explaining the commit.
