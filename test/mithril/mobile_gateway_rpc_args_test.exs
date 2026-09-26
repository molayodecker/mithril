defmodule Mithril.MobileGatewayRpcArgsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileGateway
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_availability_stub!()
    :ok
  end

  test "accepts booking start times as HH:MM the way Postgres time does" do
    user_id = Ecto.UUID.generate()

    assert {:ok, _} =
             MobileGateway.call_rpc(user_id, "get_available_cleaners_for_booking", %{
               "p_customer_id" => user_id,
               "p_booking_date" => "2026-09-26",
               "p_start_time" => "09:00",
               "p_duration_hours" => 2,
               "p_latitude" => 5.6037,
               "p_longitude" => -0.187,
               "p_max_distance_meters" => 50_000
             })
  end

  test "still accepts HH:MM:SS start times" do
    user_id = Ecto.UUID.generate()

    assert {:ok, _} =
             MobileGateway.call_rpc(user_id, "get_available_cleaners_for_booking", %{
               "p_customer_id" => user_id,
               "p_booking_date" => "2026-09-26",
               "p_start_time" => "09:00:00",
               "p_duration_hours" => 2,
               "p_latitude" => 5.6037,
               "p_longitude" => -0.187,
               "p_max_distance_meters" => 50_000
             })
  end

  test "rejects malformed booking start times" do
    user_id = Ecto.UUID.generate()

    assert {:error, :invalid_args} =
             MobileGateway.call_rpc(user_id, "get_available_cleaners_for_booking", %{
               "p_customer_id" => user_id,
               "p_booking_date" => "2026-09-26",
               "p_start_time" => "9am",
               "p_duration_hours" => 2,
               "p_latitude" => 5.6037,
               "p_longitude" => -0.187,
               "p_max_distance_meters" => 50_000
             })
  end

  defp create_availability_stub! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate RPC fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("""
    DROP FUNCTION IF EXISTS public.get_available_cleaners_for_booking(
      uuid, date, time, numeric, double precision, double precision, integer
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.get_available_cleaners_for_booking(
      p_customer_id uuid,
      p_booking_date date,
      p_start_time time without time zone,
      p_duration_hours numeric,
      p_latitude double precision,
      p_longitude double precision,
      p_max_distance_meters integer
    ) RETURNS jsonb
    LANGUAGE sql
    AS $$
      SELECT jsonb_build_object('available_cleaners', '[]'::jsonb)
    $$
    """)
  end
end
