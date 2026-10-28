defmodule Mithril.DirectPaymentRequestsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectPaymentRequests
  alias Mithril.Paystack.Test, as: PaystackTest
  alias Mithril.Repo
  alias Mithril.WhatsApp.PaymentTemplate

  @endpoint MithrilWeb.Endpoint

  setup do
    Fixtures.checkout!()
    install_schema!()
    previous = take_env()

    on_exit(fn ->
      restore_env(previous)
    end)

    Application.put_env(:mithril, :twilio_template_payment_request, "HXpayment")
    Application.put_env(:mithril, :twilio_whatsapp_admin_from, "+233559100642")
    Application.put_env(:mithril, :twilio_http, :noop)
    Application.put_env(:mithril, :twilio_auth_token, "test-signing-token")

    Application.put_env(
      :mithril,
      :twilio_payment_status_callback_url,
      "https://api.tryinstaclean.com/webhooks/twilio/payment-status"
    )

    Application.put_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
    Application.put_env(:mithril, :test_sms_messages, [])
    Application.put_env(:mithril, :paystack_test_initialize_result, :ok)
    :ok
  end

  test "the whatsapp template button is a public pay link" do
    definition = PaymentTemplate.definition()
    action = hd(definition["types"]["twilio/call-to-action"]["actions"])

    body = definition["types"]["twilio/call-to-action"]["body"]

    assert definition["friendly_name"] == "instaclean_tap_to_pay"
    refute body =~ "sign in"
    refute String.ends_with?(body, "{{3}}.")
    assert String.ends_with?(body, "Tap below to pay.")
    assert action["type"] == "URL"
    assert action["title"] == "Tap Here to Pay"
    assert action["url"] == "https://direct.tryinstaclean.com/pay/{{4}}"

    assert PaymentTemplate.variables(%{
             "customerName" => " Ama\nMensah ",
             "description" => "Deep {clean}",
             "amountLabel" => "GHS 150.00",
             "publicToken" => "abc"
           }) == %{
             "1" => "Ama Mensah",
             "2" => "GHS 150.00",
             "3" => "Deep clean",
             "4" => "abc"
           }
  end

  test "messages an unknown number on whatsapp and keeps the pay link public" do
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    assert created["channel"] == "whatsapp"
    assert created["sent"] == true
    assert created["customerUserId"] == nil
    assert created["phone"] == "+233241234567"
    assert created["amountMinor"] == 15_000
    assert created["payUrl"] == "https://direct.tryinstaclean.com/pay/#{created["publicToken"]}"
    assert String.match?(created["publicToken"], ~r/^[0-9a-f]{64}$/)

    assert {:ok, shown} = DirectPaymentRequests.public_show(created["publicToken"])

    assert shown == %{
             "customerName" => "Ama Mensah",
             "description" => "Deep clean",
             "amountMinor" => 15_000,
             "currency" => "GHS",
             "status" => "unpaid",
             "paidAt" => nil
           }

    refute Map.has_key?(shown, "phone")

    conn = get(build_conn(), "/direct/pay/#{created["publicToken"]}")
    assert json_response(conn, 200)["amountMinor"] == 15_000

    missing = get(build_conn(), "/direct/pay/not-a-token")
    assert %{"error" => "not_found"} = json_response(missing, 404)

    assert {:ok, again} = DirectPaymentRequests.create(admin_id, request())
    assert again["id"] == created["id"]
    assert again["publicToken"] == created["publicToken"]
  end

  test "texts a number that is not on whatsapp" do
    Application.put_env(:mithril, :twilio_http, {:error, :not_on_whatsapp})
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, created} =
             DirectPaymentRequests.create(
               admin_id,
               request(%{"idempotencyKey" => Ecto.UUID.generate()})
             )

    assert created["channel"] == "sms"
    assert created["sent"] == true
    assert [{phone, body}] = Application.get_env(:mithril, :test_sms_messages)
    assert phone == "+233241234567"
    assert body =~ "GHS 150.00"
    assert body =~ created["payUrl"]
    assert body =~ "Tap here to pay"
    refute body =~ "sign in"
  end

  test "does not text when whatsapp delivery is unknown" do
    Application.put_env(:mithril, :twilio_http, {:error, :twilio_unavailable})
    admin_id = Fixtures.insert_user!("admin")

    assert {:ok, created} =
             DirectPaymentRequests.create(
               admin_id,
               request(%{"idempotencyKey" => Ecto.UUID.generate()})
             )

    assert created["sent"] == false
    assert created["channel"] == nil
    assert created["deliveryError"] == "delivery_unknown"
    assert created["payUrl"] =~ "/pay/"
    assert Application.get_env(:mithril, :test_sms_messages) == []
  end

  test "links an existing customer and accepts a phone that is not on their account" do
    admin_id = Fixtures.insert_user!("admin")
    customer_id = Fixtures.insert_user!()

    Repo.query!("UPDATE public.users SET phone = $2, email = $3 WHERE id = $1", [
      Ecto.UUID.dump!(customer_id),
      "+233209998877",
      "ama@example.com"
    ])

    assert {:ok, linked} =
             DirectPaymentRequests.create(
               admin_id,
               request(%{
                 "customerUserId" => customer_id,
                 "phone" => "0241234567",
                 "idempotencyKey" => Ecto.UUID.generate()
               })
             )

    assert linked["customerUserId"] == customer_id
    assert linked["phone"] == "+233241234567"
    assert linked["email"] == "ama@example.com"

    stranger = request(%{"phone" => "0201112223", "idempotencyKey" => Ecto.UUID.generate()})
    assert {:ok, unlinked} = DirectPaymentRequests.create(admin_id, stranger)
    assert unlinked["customerUserId"] == nil

    Repo.query!("UPDATE public.users SET phone = $2 WHERE id = $1", [
      Ecto.UUID.dump!(customer_id),
      "+233201112223"
    ])

    assert {:ok, matched} =
             DirectPaymentRequests.create(
               admin_id,
               request(%{
                 "phone" => "0201112223",
                 "idempotencyKey" => Ecto.UUID.generate(),
                 "email" => nil
               })
             )

    assert matched["customerUserId"] == customer_id
    assert matched["email"] == "ama@example.com"
  end

  test "rejects a bad phone, a tiny amount, an unknown customer, and a non-admin" do
    admin_id = Fixtures.insert_user!("admin")
    customer_id = Fixtures.insert_user!()

    assert {:error, :invalid_phone} =
             DirectPaymentRequests.create(admin_id, request(%{"phone" => "nope"}))

    assert {:error, :invalid_request} =
             DirectPaymentRequests.create(admin_id, request(%{"amountMinor" => 50}))

    assert {:error, :customer_not_found} =
             DirectPaymentRequests.create(
               admin_id,
               request(%{"customerUserId" => Ecto.UUID.generate()})
             )

    assert {:error, :forbidden} = DirectPaymentRequests.create(customer_id, request())
    assert {:error, :forbidden} = DirectPaymentRequests.list(customer_id)
  end

  test "a public checkout charges the saved amount and a webhook can mark it paid" do
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    token = created["publicToken"]

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/direct/pay/#{token}/checkout", "{}")

    checkout = json_response(conn, 200)
    assert checkout["amountMinor"] == 15_000
    assert checkout["currency"] == "GHS"
    assert checkout["authorizationUrl"] =~ "https://checkout.paystack.com/"
    reference = checkout["reference"]
    assert Regex.match?(~r/^[A-Za-z0-9.=-]+$/, reference)

    assert {:ok, paid} =
             DirectPaymentRequests.settle_charge(%{
               reference: reference,
               status: "success",
               amount_minor: 15_000,
               currency: "GHS"
             })

    assert paid.settled == true
    assert {:ok, shown} = DirectPaymentRequests.public_show(token)
    assert shown["status"] == "paid"
    assert is_binary(shown["paidAt"])

    again =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/direct/pay/#{token}/checkout", "{}")

    assert %{"error" => "already_paid"} = json_response(again, 409)

    assert {:ok, %{already_paid: true}} =
             DirectPaymentRequests.settle_charge(%{
               reference: reference,
               status: "success",
               amount_minor: 15_000,
               currency: "GHS"
             })
  end

  test "verify refuses a payment whose amount does not match the request" do
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())

    assert {:ok, checkout} = DirectPaymentRequests.checkout(created["publicToken"], %{})
    reference = checkout["reference"]

    PaystackTest.put_attempt(reference, %{
      status: "success",
      amount: 100,
      currency: "GHS",
      reference: reference
    })

    assert {:error, :amount_mismatch} =
             DirectPaymentRequests.verify(created["publicToken"], %{"reference" => reference})

    assert {:ok, shown} = DirectPaymentRequests.public_show(created["publicToken"])
    assert shown["status"] == "unpaid"

    PaystackTest.put_attempt(reference, %{
      status: "success",
      amount: 15_000,
      currency: "GHS",
      reference: reference
    })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/direct/pay/#{created["publicToken"]}/verify",
        Jason.encode!(%{"reference" => reference})
      )

    assert json_response(conn, 200)["status"] == "paid"
  end

  test "an unknown paystack reference is not a payment request" do
    assert :unknown =
             DirectPaymentRequests.settle_charge(%{
               reference: "missing",
               status: "success",
               amount_minor: 15_000,
               currency: "GHS"
             })
  end

  test "ambiguous Paystack initialization rotates the reference and retains late settlement" do
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    token = created["publicToken"]
    Application.put_env(:mithril, :paystack_test_initialize_result, :ambiguous_once)

    assert {:error, :payment_unavailable} = DirectPaymentRequests.checkout(token, %{})

    [[old_reference]] =
      Repo.query!("SELECT reference FROM public.direct_payment_request_references LIMIT 1").rows

    assert {:ok, checkout} = DirectPaymentRequests.checkout(token, %{})
    refute checkout["reference"] == old_reference

    assert {:ok, %{settled: true}} =
             DirectPaymentRequests.settle_charge(%{
               reference: old_reference,
               status: "success",
               amount_minor: 15_000,
               currency: "GHS"
             })

    assert {:ok, shown} = DirectPaymentRequests.public_show(token)
    assert shown["status"] == "paid"
    assert {:ok, verified} = DirectPaymentRequests.verify(token, %{"reference" => old_reference})
    assert verified["status"] == "paid"
  end

  test "late WhatsApp delivery failure sends only one SMS fallback" do
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    token = created["publicToken"]
    params = %{"MessageSid" => "SMtest-payment-request", "MessageStatus" => "undelivered"}
    url = "https://api.tryinstaclean.com/webhooks/twilio/payment-status/#{token}"
    payload = Enum.reduce(Enum.sort(params), url, fn {key, value}, acc -> acc <> key <> value end)
    signature = :crypto.mac(:hmac, :sha, "test-signing-token", payload) |> Base.encode64()

    for _ <- 1..2 do
      conn =
        build_conn()
        |> put_req_header("x-twilio-signature", signature)
        |> post("/webhooks/twilio/payment-status/#{token}", params)

      assert conn.status == 204
    end

    assert [{"+233241234567", body}] = Application.get_env(:mithril, :test_sms_messages)
    assert body =~ created["payUrl"]

    assert [["sms"]] =
             Repo.query!(
               "SELECT channel FROM public.direct_payment_requests WHERE public_token = $1",
               [token]
             ).rows
  end

  test "a definitively unsent SMS fallback can retry on a signed callback" do
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    token = created["publicToken"]
    params = %{"MessageSid" => "SMtest-payment-request", "MessageStatus" => "undelivered"}
    url = "https://api.tryinstaclean.com/webhooks/twilio/payment-status/#{token}"
    payload = Enum.reduce(Enum.sort(params), url, fn {key, value}, acc -> acc <> key <> value end)
    signature = :crypto.mac(:hmac, :sha, "test-signing-token", payload) |> Base.encode64()

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Disabled)

    assert {:error, :sms_retryable} =
             DirectPaymentRequests.payment_status_callback(token, params, signature)

    assert [[nil]] =
             Repo.query!(
               "SELECT sms_fallback_claimed_at FROM public.direct_payment_requests WHERE public_token = $1",
               [token]
             ).rows

    Application.put_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Test)
    assert :ok = DirectPaymentRequests.payment_status_callback(token, params, signature)
    assert [{"+233241234567", _}] = Application.get_env(:mithril, :test_sms_messages)
  end

  test "template approval is retried without creating duplicate content" do
    Application.delete_env(:mithril, :twilio_template_payment_request)
    caller = self()

    Application.put_env(:mithril, :twilio_content_http, fn
      :create, _body ->
        send(caller, :created)
        {:ok, "HXgenerated"}

      :approve, _body ->
        send(caller, :approval_attempt)

        if Process.get(:approval_failed_once) do
          :ok
        else
          Process.put(:approval_failed_once, true)
          {:error, :temporary_failure}
        end
    end)

    assert {:error, :temporary_failure} = PaymentTemplate.ensure()
    assert {:ok, "HXgenerated"} = PaymentTemplate.ensure()
    assert_received :created
    assert_received :approval_attempt
    assert_received :approval_attempt
    refute_received :created

    assert [["submitted"]] =
             Repo.query!(
               "SELECT approval_status FROM public.whatsapp_content_templates WHERE name = 'instaclean_tap_to_pay'"
             ).rows
  end

  test "a delivery claim prevents replay after an uncertain provider response" do
    Application.put_env(:mithril, :twilio_http, {:error, :twilio_unavailable})
    admin_id = Fixtures.insert_user!("admin")
    assert {:ok, created} = DirectPaymentRequests.create(admin_id, request())
    assert created["sent"] == false

    assert {:ok, replayed} = DirectPaymentRequests.create(admin_id, request())
    assert replayed["id"] == created["id"]
    assert Application.get_env(:mithril, :test_sms_messages) == []

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM public.direct_payment_requests WHERE delivery_claimed_at IS NOT NULL"
             ).rows
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "customerName" => "Ama Mensah",
        "phone" => "0241234567",
        "description" => "Deep clean",
        "amountMinor" => 15_000,
        "idempotencyKey" => "6d5f0b2e-1c3a-4f61-9a2d-0e5b7c8d9f10"
      },
      overrides
    )
  end

  defp install_schema! do
    path =
      Path.expand(
        "../../priv/repo/sql/direct/20261028023000_direct_payment_requests.sql",
        __DIR__
      )

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) |> String.starts_with?("--")))
    |> Enum.join("\n")
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Repo.query!/1)
  end

  defp take_env do
    [
      :twilio_template_payment_request,
      :twilio_whatsapp_admin_from,
      :twilio_http,
      :twilio_auth_token,
      :twilio_payment_status_callback_url,
      :paystack_test_initialize_result,
      :twilio_content_http,
      :sms_adapter,
      :direct_public_url,
      :test_sms_messages
    ]
    |> Map.new(fn key -> {key, Application.get_env(:mithril, key)} end)
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:mithril, key)
      {key, value} -> Application.put_env(:mithril, key, value)
    end)
  end
end
