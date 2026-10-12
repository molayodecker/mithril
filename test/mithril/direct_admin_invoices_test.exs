defmodule Mithril.DirectAdminInvoicesTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Mithril.DirectAdminInvoices
  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint
  @admin_from "+233559100642"

  setup do
    Fixtures.checkout!()
    previous = take_env()

    on_exit(fn ->
      restore_env(previous)
    end)

    :ok
  end

  test "multiplies quantity, days, and unit price in pesewas" do
    assert DirectAdminInvoices.line_total_minor(5, 3, 20_000) == {:ok, 300_000}
    assert DirectAdminInvoices.line_total_minor(nil, nil, 30_000) == {:ok, 30_000}
    assert DirectAdminInvoices.line_total_minor(2, nil, 10_000) == :error
    assert DirectAdminInvoices.line_total_minor(10_000, 10_000, 2_147_483_647) == :error
  end

  test "whatsapp message carries the total due and the invoice link" do
    body = DirectAdminInvoices.whatsapp_message(sample_message(), invoice_url("abc"))

    assert body =~ "Instaclean invoice 12"
    assert body =~ "Cleaners: 5 x 3 x GHS 200.00 = GHS 3,000.00"
    assert body =~ "Transport and other expenses: GHS 300.00"
    assert body =~ "Total due: GHS 4,800.00"
    assert body =~ invoice_url("abc")
    assert String.length(body) <= 2000
    assert DirectAdminInvoices.money(-15_000) == "−GHS 150.00"
    assert DirectAdminInvoices.money(1_000_000) == "GHS 10,000.00"
  end

  test "a long whatsapp message stays within the session limit" do
    lines =
      for n <- 1..20 do
        %{
          "description" => "Line #{n} " <> String.duplicate("work", 30),
          "qty" => 2,
          "days" => 4,
          "unitMinor" => 12_500,
          "totalMinor" => 100_000
        }
      end

    invoice = Map.put(sample_message(), "lines", lines)
    body = DirectAdminInvoices.whatsapp_message(invoice, invoice_url("abc"))

    assert String.length(body) <= 2000
    assert body =~ "…"
    assert body =~ "Total due: GHS 4,800.00"
  end

  test "an invalid public token is not found and does not require a login" do
    conn = get(build_conn(), "/direct/invoices/not-a-token")
    assert %{"error" => "invoice_not_found"} = json_response(conn, 404)

    assert {:error, :invoice_not_found} = DirectAdminInvoices.public_show("short")

    assert {:error, :invoice_not_found} =
             DirectAdminInvoices.public_show(String.duplicate("ab", 32))
  end

  test "saving an invoice computes the sample total and keeps the public token" do
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, saved} = DirectAdminInvoices.upsert(admin_id, booking_id, sample_invoice())
    assert saved["invoiceNo"] == "12"
    assert saved["subtotalMinor"] == 495_000
    assert saved["adjustmentMinor"] == -15_000
    assert saved["totalMinor"] == 480_000
    assert saved["billToPhone"] == "+233241234567"
    assert saved["billToEmail"] == "lucy@example.com"
    assert saved["lines"] |> Enum.map(& &1["totalMinor"]) == [300_000, 110_000, 55_000, 30_000]
    assert String.match?(saved["publicToken"], ~r/^[0-9a-f]{64}$/)
    assert saved["viewUrl"] == invoice_url(saved["publicToken"])

    assert {:ok, shown} = DirectAdminInvoices.show(admin_id, booking_id)
    assert shown["publicToken"] == saved["publicToken"]

    assert {:ok, public} = DirectAdminInvoices.public_show(saved["publicToken"])
    assert public["totalMinor"] == 480_000
    assert public["bookingId"] == booking_id

    updated =
      sample_invoice(%{"project" => "Revised clean", "adjustmentMinor" => 0, "invoiceNo" => nil})

    assert {:ok, again} = DirectAdminInvoices.upsert(admin_id, booking_id, updated)
    assert again["publicToken"] == saved["publicToken"]
    assert again["invoiceNo"] == "12"
    assert again["totalMinor"] == 495_000
    assert again["project"] == "Revised clean"
  end

  test "changing recipient details revokes the previous public invoice link" do
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, first} = DirectAdminInvoices.upsert(admin_id, booking_id, sample_invoice())
    old_token = first["publicToken"]

    assert {:ok, revised} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToName" => "Different customer"})
             )

    refute revised["publicToken"] == old_token
    assert {:error, :invoice_not_found} = DirectAdminInvoices.public_show(old_token)
    assert {:ok, latest} = DirectAdminInvoices.public_show(revised["publicToken"])
    assert latest["billToName"] == "Different customer"
  end

  test "a blank invoice number takes the next sequence value" do
    admin_id = Fixtures.insert_user!("admin")
    first = Fixtures.insert_booking!(Fixtures.insert_user!())
    second = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, one} =
             DirectAdminInvoices.upsert(admin_id, first, sample_invoice(%{"invoiceNo" => nil}))

    assert {:ok, two} =
             DirectAdminInvoices.upsert(admin_id, second, sample_invoice(%{"invoiceNo" => ""}))

    assert one["invoiceNo"] =~ ~r/^\d+$/
    assert two["invoiceNo"] =~ ~r/^\d+$/
    refute one["invoiceNo"] == two["invoiceNo"]
  end

  test "the database rejects invoice totals a client must not invent" do
    admin_id = Fixtures.insert_user!("admin")
    customer_id = Fixtures.insert_user!()
    booking_id = Fixtures.insert_booking!(customer_id)
    stranger_id = Fixtures.insert_user!()

    assert {:error, :booking_not_found} =
             DirectAdminInvoices.upsert(admin_id, Ecto.UUID.generate(), sample_invoice())

    assert {:error, :forbidden} =
             DirectAdminInvoices.upsert(stranger_id, booking_id, sample_invoice())

    assert {:error, :forbidden} = DirectAdminInvoices.show(stranger_id, booking_id)
    assert {:error, :invalid_request} = DirectAdminInvoices.show(admin_id, "not-a-booking")

    assert sql_error(admin_id, booking_id, sample_invoice(%{"lines" => [half_line()]})) =~
             "invalid_lines"

    assert sql_error(admin_id, booking_id, sample_invoice(%{"lines" => [overflow_line()]})) =~
             "amount_too_large"

    assert sql_error(admin_id, booking_id, sample_invoice(%{"billToEmail" => "not-an-email"})) =~
             "invalid_email"

    assert sql_error(stranger_id, booking_id, sample_invoice()) =~ "recorded_by_not_authorized"
    assert sql_error(admin_id, Ecto.UUID.generate(), sample_invoice()) =~ "booking_not_found"
  end

  test "invoice validation fails before a send" do
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:error, :invalid_lines} =
             DirectAdminInvoices.upsert(admin_id, booking_id, sample_invoice(%{"lines" => []}))

    assert {:error, :invalid_lines} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"lines" => [half_line()]})
             )

    assert {:error, :invalid_phone} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToPhone" => "abc"})
             )

    assert {:error, :invalid_email} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToEmail" => "lucy"})
             )

    assert {:error, :invalid_invoice} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"issuedOn" => "2026-02-31"})
             )

    assert {:error, :invalid_invoice} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToName" => "  "})
             )

    assert {:error, :invoice_not_found} =
             DirectAdminInvoices.public_show(String.duplicate("ab", 32))

    assert {:error, :invoice_not_found} = DirectAdminInvoices.show(admin_id, booking_id)
  end

  test "whatsapp send stores the message and records when it went out" do
    Application.put_env(:mithril, :twilio_whatsapp_admin_from, @admin_from)
    Application.put_env(:mithril, :twilio_http, :noop)
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())
    assert {:ok, _} = DirectAdminInvoices.upsert(admin_id, booking_id, sample_invoice())

    assert {:ok, %{"ok" => true, "channel" => "whatsapp", "sent" => true}} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "whatsapp"})

    assert {:ok, shown} = DirectAdminInvoices.show(admin_id, booking_id)
    assert is_binary(shown["lastWhatsappSentAt"])

    [[body]] =
      Repo.query!("SELECT body FROM public.whatsapp_inbox_messages WHERE direction = 'outbound'").rows

    assert body =~ "Total due: GHS 4,800.00"
    assert body =~ shown["viewUrl"]
  end

  test "whatsapp send reports a missing number, a missing line, and a failed delivery" do
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, _} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToPhone" => nil})
             )

    assert {:error, :missing_phone} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "whatsapp"})

    assert {:error, :invalid_request} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "sms"})

    assert {:ok, _} = DirectAdminInvoices.upsert(admin_id, booking_id, sample_invoice())
    Application.delete_env(:mithril, :twilio_whatsapp_admin_from)

    assert {:error, :twilio_not_configured} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "whatsapp"})

    Application.put_env(:mithril, :twilio_whatsapp_admin_from, @admin_from)
    Application.put_env(:mithril, :twilio_http, {:error, :twilio_failed})

    assert {:error, :sms_delivery_failed} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "whatsapp"})
  end

  test "email send escapes the invoice and records a failure from the mail provider" do
    admin_id = Fixtures.insert_user!("admin")
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    named =
      sample_invoice(%{"billToName" => "Lucy <script>", "billToEmail" => "lucy@example.com"})

    assert {:ok, _} = DirectAdminInvoices.upsert(admin_id, booking_id, named)

    Application.put_env(:mithril, :resend_api_key, "")

    assert {:error, :email_not_configured} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "email"})

    {:ok, agent} = Agent.start_link(fn -> nil end)

    Req.Test.stub(Mithril.DirectAdminInvoices, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      Agent.update(agent, fn _ -> raw end)
      Req.Test.json(conn, %{"id" => "email_1"})
    end)

    Application.put_env(:mithril, :resend_api_key, "re_test")

    Application.put_env(:mithril, :resend_req_options,
      plug: {Req.Test, Mithril.DirectAdminInvoices}
    )

    assert {:ok, %{"channel" => "email", "sent" => true}} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "email"})

    assert Agent.get(agent, & &1) =~ "Lucy &lt;script&gt;"
    assert {:ok, shown} = DirectAdminInvoices.show(admin_id, booking_id)
    assert is_binary(shown["lastEmailSentAt"])

    Req.Test.stub(Mithril.DirectAdminInvoices, fn conn ->
      Plug.Conn.send_resp(conn, 500, "nope")
    end)

    assert {:error, :email_delivery_failed} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "email"})

    assert {:ok, _} =
             DirectAdminInvoices.upsert(
               admin_id,
               booking_id,
               sample_invoice(%{"billToEmail" => nil})
             )

    assert {:error, :missing_email} =
             DirectAdminInvoices.send(admin_id, booking_id, %{"channel" => "email"})
  end

  defp sample_message do
    %{
      "invoiceNo" => "12",
      "project" => "Post Construction Cleaning",
      "billToName" => "Madam Lucy",
      "totalMinor" => 480_000,
      "lines" => [
        %{
          "description" => "Cleaners",
          "qty" => 5,
          "days" => 3,
          "unitMinor" => 20_000,
          "totalMinor" => 300_000
        },
        %{
          "description" => "Transport and other expenses",
          "qty" => nil,
          "days" => nil,
          "unitMinor" => 30_000,
          "totalMinor" => 30_000
        }
      ]
    }
  end

  defp sample_invoice(overrides \\ %{}) do
    Map.merge(
      %{
        "invoiceNo" => "12",
        "issuedOn" => "2026-10-10",
        "billToName" => "Madam Lucy",
        "billToAddress" => "Cantonments",
        "billToPhone" => "0241234567",
        "billToEmail" => "Lucy@Example.com",
        "project" => "Post Construction Cleaning",
        "lines" => [
          %{"description" => "Cleaners", "qty" => 5, "days" => 3, "unitMinor" => 20_000},
          %{
            "description" => "Floor Scrubber and Operator",
            "qty" => 1,
            "days" => 2,
            "unitMinor" => 55_000
          },
          %{
            "description" => "Vacuum cleaner and operator",
            "qty" => 1,
            "days" => 1,
            "unitMinor" => 55_000
          },
          %{
            "description" => "Transport and other expenses",
            "qty" => nil,
            "days" => nil,
            "unitMinor" => 30_000
          }
        ],
        "adjustmentMinor" => -15_000,
        "notes" => "Gate code 12"
      },
      overrides
    )
  end

  defp half_line do
    %{"description" => "Visit", "qty" => 2, "days" => nil, "unitMinor" => 1_000}
  end

  defp overflow_line do
    %{"description" => "Too much", "qty" => 10_000, "days" => 10_000, "unitMinor" => 100_000}
  end

  defp sql_error(admin_id, booking_id, invoice) do
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Repo.query(
               """
               SELECT public.upsert_admin_job_invoice($1::uuid, $2::uuid, $3::jsonb)
               """,
               [Ecto.UUID.dump!(booking_id), Ecto.UUID.dump!(admin_id), invoice]
             )

    message
  end

  defp invoice_url(token) do
    "https://direct.tryinstaclean.com/invoices/#{token}"
  end

  defp take_env do
    %{
      from: Application.get_env(:mithril, :twilio_whatsapp_admin_from),
      http: Application.get_env(:mithril, :twilio_http),
      key: Application.get_env(:mithril, :resend_api_key),
      req: Application.get_env(:mithril, :resend_req_options)
    }
  end

  defp restore_env(previous) do
    put_or_delete(:twilio_whatsapp_admin_from, previous.from)
    put_or_delete(:twilio_http, previous.http)
    put_or_delete(:resend_api_key, previous.key)
    put_or_delete(:resend_req_options, previous.req)
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:mithril, key)
  defp put_or_delete(key, value), do: Application.put_env(:mithril, key, value)
end
