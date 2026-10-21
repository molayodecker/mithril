defmodule Mithril.MobileFunctions.GatewayAuthTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions
  alias Mithril.MobileFunctions.UberTransportationReleaseGate

  test "forbids OTP theft and open notification relay on the authenticated invoke path" do
    user_id = Ecto.UUID.generate()

    assert {:error, :forbidden} =
             MobileFunctions.invoke(user_id, "fetch-otp-delivery-token", %{
               "phone" => "+233201234567"
             })

    assert {:error, :forbidden} =
             MobileFunctions.invoke(user_id, "resend-otp-via-channel", %{
               "phone" => "+233201234567"
             })

    assert {:error, :forbidden} =
             MobileFunctions.invoke(user_id, "send-notification", %{
               "userId" => Ecto.UUID.generate()
             })
  end

  test "uber release gate reports whether transportation is enabled" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
    user_id = Ecto.UUID.generate()

    assert match?(
             {:ok, %{enabled: enabled}} when is_boolean(enabled),
             UberTransportationReleaseGate.call(user_id, %{})
           ) or
             match?({:error, {:status, 503, _}}, UberTransportationReleaseGate.call(user_id, %{}))
  end

  test "gateway exposes trip estimate and rejects invalid coordinates before routing" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "Invalid customer_latitude"}}} =
             Mithril.MobileGateway.invoke_function(user_id, "uber-trip-estimate", %{
               "cleaner_id" => Ecto.UUID.generate(),
               "customer_latitude" => 95,
               "customer_longitude" => -0.2
             })
  end

  test "rejects trip estimates without a server-authorized booking" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "Invalid booking_id"}}} =
             Mithril.MobileGateway.invoke_function(user_id, "uber-trip-estimate", %{
               "cleaner_id" => Ecto.UUID.generate(),
               "customer_latitude" => 5.6037,
               "customer_longitude" => -0.187
             })
  end
end

defmodule Mithril.MobileFunctions.UberTripEstimateAuthorizationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_bookings_table!()
    :ok
  end

  test "hides a booking the caller does not own before reading the cleaner origin" do
    caller_id = Ecto.UUID.generate()
    cleaner_id = Ecto.UUID.generate()
    booking_id = insert_booking!(Ecto.UUID.generate(), cleaner_id)

    assert {:error, {:status, 404, %{error: "Booking not found"}}} =
             Mithril.MobileGateway.invoke_function(caller_id, "uber-trip-estimate", %{
               "cleaner_id" => cleaner_id,
               "customer_latitude" => 5.6037,
               "customer_longitude" => -0.187,
               "booking_id" => booking_id
             })
  end

  defp insert_booking!(customer_id, cleaner_id) do
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings
        (id, customer_id, cleaner_id, status, address, location_coordinates)
      VALUES ($1, $2, $3, 'confirmed', 'East Legon, Accra',
              '{"latitude": 5.65, "longitude": -0.18}'::jsonb)
      """,
      [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(customer_id), Ecto.UUID.dump!(cleaner_id)]
    )

    booking_id
  end

  defp create_bookings_table! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate bookings; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.bookings")

    Repo.query!("""
    CREATE TABLE public.bookings (
      id uuid PRIMARY KEY,
      customer_id uuid NOT NULL,
      cleaner_id uuid,
      status text,
      address text,
      location_coordinates jsonb
    )
    """)
  end
end

defmodule Mithril.MobileFunctions.TimezoneTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.Timezone

  test "requires latitude and longitude" do
    assert {:error, {:status, 400, body}} = Timezone.call(%{})
    assert body.error =~ "Latitude"
  end

  test "rejects non-numeric coordinates" do
    assert {:error, {:status, 400, _body}} = Timezone.call(%{"lat" => "abc", "lng" => "1"})
  end
end

defmodule Mithril.MobileFunctions.PaystackTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.Paystack

  test "fetch_banks returns configured error when secret missing" do
    previous = Application.get_env(:mithril, :paystack_secret_key)
    Application.delete_env(:mithril, :paystack_secret_key)

    on_exit(fn ->
      if previous, do: Application.put_env(:mithril, :paystack_secret_key, previous)
    end)

    assert {:error, {:status, 500, %{ok: false, error: message}}} =
             Paystack.fetch_banks(%{"currency" => "GHS"})

    assert message =~ "Paystack"
  end

  test "resolve_bank_account validates account number shape" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Invalid account number"}}} =
             Paystack.resolve_bank_account(user_id, %{
               "account_number" => "12",
               "bank_code" => "MTN"
             })
  end

  test "create_transfer_recipient validates recipient type" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Invalid recipient type"}}} =
             Paystack.create_transfer_recipient(user_id, %{"type" => "card"})
  end

  test "initiate_transfer rejects invalid recipient code" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Invalid recipient code"}}} =
             Paystack.initiate_transfer(user_id, %{
               "amount" => 10_000,
               "recipient" => "bad-code"
             })
  end

  test "initiate_transfer rejects unsupported withdrawal currency" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Unsupported currency"}}} =
             Paystack.initiate_transfer(user_id, %{
               "amount" => 10_000,
               "recipient" => "RCP_test123",
               "currency" => "EUR"
             })
  end

  test "initiate_transfer enforces minimum withdrawal" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Minimum withdrawal is GHS 50.00"}}} =
             Paystack.initiate_transfer(user_id, %{
               "amount" => 100,
               "recipient" => "RCP_test123"
             })
  end
end
