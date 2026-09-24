defmodule Mithril.MobileFunctions.SendAppNotificationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileFunctions.SendAppNotification
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_tables!()
    :ok
  end

  test "hides unknown bookings instead of leaking existence" do
    cleaner_id = Ecto.UUID.generate()

    assert {:error, {:status, 404, %{success: false, error: "Booking not found"}}} =
             SendAppNotification.call(cleaner_id, %{
               "type" => "cleaner_en_route",
               "targetUserId" => Ecto.UUID.generate(),
               "payload" => %{"bookingId" => Ecto.UUID.generate()}
             })
  end

  test "reclaims a stale dispatching milestone instead of reporting already_sent" do
    {cleaner_id, customer_id, booking_id} = insert_en_route_booking!()
    insert_milestone!(booking_id, cleaner_id, customer_id, "dispatching", minutes_ago: 6)

    assert {:ok, result} =
             SendAppNotification.call(cleaner_id, %{
               "type" => "cleaner_en_route",
               "targetUserId" => customer_id,
               "payload" => %{"bookingId" => booking_id}
             })

    refute result.duplicate
  end

  test "does not reclaim an in-flight dispatching milestone" do
    {cleaner_id, customer_id, booking_id} = insert_en_route_booking!()
    insert_milestone!(booking_id, cleaner_id, customer_id, "dispatching", minutes_ago: 0)

    assert {:ok, %{duplicate: true, reason: "already_sent"}} =
             SendAppNotification.call(cleaner_id, %{
               "type" => "cleaner_en_route",
               "targetUserId" => customer_id,
               "payload" => %{"bookingId" => booking_id}
             })
  end

  defp insert_en_route_booking! do
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (id, cleaner_id, customer_id, status, address)
      VALUES ($1, $2, $3, 'en_route', 'East Legon')
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(cleaner_id), Ecto.UUID.dump!(customer_id)]
    )

    {cleaner_id, customer_id, booking_id}
  end

  defp insert_milestone!(booking_id, cleaner_id, customer_id, status, minutes_ago: minutes_ago) do
    Repo.query!(
      """
      INSERT INTO public.booking_milestone_notifications
        (booking_id, milestone, cleaner_id, customer_id, status, inserted_at, updated_at)
      VALUES (
        $1, 'cleaner_en_route', $2, $3, $4,
        NOW() - ($5::int * INTERVAL '1 minute'),
        NOW() - ($5::int * INTERVAL '1 minute')
      )
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(cleaner_id),
        Ecto.UUID.dump!(customer_id),
        status,
        minutes_ago
      ]
    )
  end

  defp create_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate tables; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.booking_milestone_notifications")
    Repo.query!("DROP TABLE IF EXISTS public.bookings")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      cleaner_id uuid,
      customer_id uuid,
      customer_contact_phone text,
      status text,
      address text,
      scheduled_date date,
      scheduled_time time,
      title text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.booking_milestone_notifications (
      booking_id uuid NOT NULL,
      milestone text NOT NULL,
      cleaner_id uuid NOT NULL,
      customer_id uuid NOT NULL,
      status text NOT NULL DEFAULT 'pending',
      delivered_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT NOW(),
      updated_at timestamptz NOT NULL DEFAULT NOW(),
      PRIMARY KEY (booking_id, milestone),
      CONSTRAINT booking_milestone_notifications_milestone_check
        CHECK (milestone IN ('cleaner_en_route', 'cleaner_arrived')),
      CONSTRAINT booking_milestone_notifications_status_check
        CHECK (status IN ('pending', 'dispatching', 'delivered'))
    )
    """)
  end
end
