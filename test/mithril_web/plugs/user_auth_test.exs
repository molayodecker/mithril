defmodule MithrilWeb.Plugs.UserAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias Mithril.Auth.Token
  alias MithrilWeb.Plugs.UserAuth

  test "rejects requests without a bearer token" do
    conn = UserAuth.call(build_conn(), [])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "assigns the user id from a Mithril access JWT" do
    user_id = Ecto.UUID.generate()
    {:ok, access_token, _claims} = Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> UserAuth.call([])

    refute conn.halted
    assert conn.assigns.instaclean_user_id == user_id
  end
end
