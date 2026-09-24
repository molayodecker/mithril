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

  test "uber release gate is a read-only flag lookup" do
    user_id = Ecto.UUID.generate()

    assert {:ok, %{enabled: enabled}} = UberTransportationReleaseGate.call(user_id, %{})
    assert is_boolean(enabled)
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

  test "initiate_transfer enforces minimum withdrawal" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{ok: false, error: "Minimum withdrawal is GHS 50.00"}}} =
             Paystack.initiate_transfer(user_id, %{
               "amount" => 100,
               "recipient" => "RCP_test123"
             })
  end
end
