defmodule PlugTestHelpers.DebugPlug do
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
