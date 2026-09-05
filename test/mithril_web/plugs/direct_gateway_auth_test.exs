defmodule MithrilWeb.Plugs.DirectGatewayAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias MithrilWeb.Plugs.DirectGatewayAuth

  @token "direct-test-token"

  setup do
    :ok = Sandbox.checkout(Repo)

    Repo.query!("DROP TABLE IF EXISTS public.users CASCADE")

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    previous = Application.get_env(:mithril, :direct_gateway_token)
    Application.put_env(:mithril, :direct_gateway_token, @token)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mithril, :direct_gateway_token)
      else
        Application.put_env(:mithril, :direct_gateway_token, previous)
      end
    end)

    :ok
  end

  test "rejects requests without the server token" do
    conn = DirectGatewayAuth.call(build_conn(), [])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "rejects an invalid canonical user id" do
    conn =
      build_conn()
      |> put_req_header("x-mithril-direct-token", @token)
      |> put_req_header("x-instaclean-user-id", "not-a-uuid")
      |> DirectGatewayAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_user"}
  end

  test "assigns the validated canonical user id" do
    user_id = insert_user("active")

    conn =
      build_conn()
      |> put_req_header("x-mithril-direct-token", @token)
      |> put_req_header("x-instaclean-user-id", user_id)
      |> DirectGatewayAuth.call([])

    refute conn.halted
    assert conn.assigns.instaclean_user_id == user_id
  end

  test "rejects a suspended canonical user from the gateway path" do
    user_id = insert_user("suspended")

    conn =
      build_conn()
      |> put_req_header("x-mithril-direct-token", @token)
      |> put_req_header("x-instaclean-user-id", user_id)
      |> DirectGatewayAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_user"}
  end

  test "accepts a Mithril user JWT without the Direct gateway token" do
    user_id = insert_user("active")
    {:ok, access_token, _claims} = Mithril.Auth.Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> DirectGatewayAuth.call([])

    refute conn.halted
    assert conn.assigns.instaclean_user_id == user_id
  end

  test "rejects an otherwise valid JWT after the user is suspended" do
    user_id = insert_user("suspended")
    {:ok, access_token, _claims} = Mithril.Auth.Token.issue(user_id, "jwt@example.com")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> DirectGatewayAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_user"}
  end

  defp insert_user(status) do
    user_id = Ecto.UUID.generate()
    {:ok, dumped_user_id} = Ecto.UUID.dump(user_id)

    Repo.query!("INSERT INTO public.users (id, status) VALUES ($1::uuid, $2)", [
      dumped_user_id,
      status
    ])

    user_id
  end
end
