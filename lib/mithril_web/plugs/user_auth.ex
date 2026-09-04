defmodule MithrilWeb.Plugs.UserAuth do
  @moduledoc false

  import Plug.Conn

  alias Mithril.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        reject(conn, 401, "unauthorized")

      token ->
        case Token.verify_access(token) do
          {:ok, %{"sub" => user_id}} when is_binary(user_id) ->
            assign(conn, :instaclean_user_id, user_id)

          _other ->
            reject(conn, 401, "unauthorized")
        end
    end
  end

  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp reject(conn, status, error) do
    body = Jason.encode!(%{error: error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
