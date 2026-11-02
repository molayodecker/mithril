defmodule MithrilWeb.Plugs.UserAuth do
  @moduledoc false

  import Plug.Conn

  alias Mithril.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, conn} -> conn
      :error -> reject(conn, 401, "unauthorized")
    end
  end

  def authenticate(conn) do
    case bearer_token(conn) do
      nil ->
        :error

      token ->
        case Token.verify_access(token) do
          {:ok, %{"sub" => user_id} = claims} when is_binary(user_id) ->
            {:ok,
             conn
             |> assign(:instaclean_user_id, user_id)
             |> assign(:auth_purpose, password_reset_purpose(claims))}

          _other ->
            :error
        end
    end
  end

  defp password_reset_purpose(%{"purpose" => "password_reset"}), do: "password_reset"
  defp password_reset_purpose(_claims), do: nil

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
