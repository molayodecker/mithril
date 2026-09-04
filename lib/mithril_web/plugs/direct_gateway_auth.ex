defmodule MithrilWeb.Plugs.DirectGatewayAuth do
  @moduledoc false

  import Plug.Conn

  @token_header "x-mithril-direct-token"
  @user_header "x-instaclean-user-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    configured_token = Application.get_env(:mithril, :direct_gateway_token)
    request_token = conn |> get_req_header(@token_header) |> List.first()
    user_id = conn |> get_req_header(@user_header) |> List.first()

    cond do
      not is_binary(configured_token) or configured_token == "" ->
        reject(conn, 503, "direct_gateway_not_configured")

      not secure_equal?(configured_token, request_token) ->
        reject(conn, 401, "unauthorized")

      not valid_uuid?(user_id) ->
        reject(conn, 401, "invalid_user")

      true ->
        assign(conn, :instaclean_user_id, user_id)
    end
  end

  defp secure_equal?(expected, actual)
       when is_binary(actual) and byte_size(expected) == byte_size(actual) do
    Plug.Crypto.secure_compare(expected, actual)
  end

  defp secure_equal?(_expected, _actual), do: false

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp reject(conn, status, error) do
    body = Jason.encode!(%{error: error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
