defmodule Mithril.Pay2OwnTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint
  @token "test-pay2own-token"
  @cleaner "11111111-1111-4111-8111-111111111111"

  setup do
    :ok = Sandbox.checkout(Repo)
    {:ok, id} = Ecto.UUID.dump(@cleaner)
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      phone text
    )
    """)

    Repo.query!("ALTER TABLE public.users ADD COLUMN IF NOT EXISTS phone text")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL,
      PRIMARY KEY (user_id, role_id)
    )
    """)

    Repo.query!("DELETE FROM public.user_roles WHERE user_id = $1", [id])
    Repo.query!("DELETE FROM public.users WHERE id = $1", [id])

    Repo.query!(
      "INSERT INTO public.users (id, phone) VALUES ($1, $2)",
      [id, "+233241110000"]
    )

    Repo.query!(
      "INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'cleaner')",
      [id]
    )

    previous = Application.get_env(:mithril, :pay2own_intake_token)
    Application.put_env(:mithril, :pay2own_intake_token, @token)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :pay2own_intake_token, previous)
      else
        Application.delete_env(:mithril, :pay2own_intake_token)
      end
    end)

    :ok
  end

  test "a cleaner phone is an account and an unknown phone is not" do
    found = json_response(post_lookup(%{"phone" => "0241110000"}), 200)
    assert found == %{"account" => true}

    missing = json_response(post_lookup(%{"phone" => "0240000000"}), 200)
    assert missing == %{"account" => false}
  end

  test "a cleaner id is an account" do
    body = json_response(post_lookup(%{"workerId" => @cleaner}), 200)
    assert body == %{"account" => true}
  end

  test "a longer international number cannot match a stored local Ghana number" do
    Repo.query!("UPDATE public.users SET phone = '0241110000' WHERE id::text = $1", [@cleaner])

    assert json_response(post_lookup(%{"phone" => "+2332411100009"}), 200) ==
             %{"account" => false}

    assert json_response(post_lookup(%{"phone" => "0241110000"}), 200) ==
             %{"account" => true}
  end

  test "a wrong token is unauthorized without revealing account presence" do
    conn =
      build_conn()
      |> put_req_header("x-pay2own-token", "incorrect-token")
      |> post("/pay2own/workers/lookup", %{"phone" => "0241110000"})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "a missing configured token returns 503 instead of running Mix at runtime" do
    Application.delete_env(:mithril, :pay2own_intake_token)
    assert json_response(post_lookup(%{"phone" => "0241110000"}), 503) ==
             %{"error" => "not_configured"}
  end

  test "the lookup token is required" do
    conn = post(build_conn(), "/pay2own/workers/lookup", %{"phone" => "0241110000"})
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  defp post_lookup(body) do
    build_conn()
    |> put_req_header("x-pay2own-token", @token)
    |> post("/pay2own/workers/lookup", body)
  end
end
