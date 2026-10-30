defmodule Mithril.DirectPaymentRequests do
  @moduledoc """
  Staff-created payment requests.

  The customer may already have an account, or may only have a phone number
  typed on the billing desk. Delivery uses the WhatsApp payment template when
  that number is on WhatsApp, and SMS otherwise. The link is public.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.Auth.SMS
  alias Mithril.DirectAdminInvoices
  alias Mithril.Paystack
  alias Mithril.Repo
  alias Mithril.WhatsApp.PaymentTemplate
  alias Mithril.WhatsApp.Recruitment.Outbound
  alias Mithril.WhatsApp.TwilioSignature
  alias Mithril.Workers.PaymentRequestReminder

  @columns ~w(
    id public_token customer_user_id customer_name phone_e164 email description
    amount_minor currency status channel paystack_reference authorization_url
    delivery_error idempotency_key delivery_claimed_at twilio_message_sid
    sms_fallback_claimed_at sent_at remind_if_unpaid reminders_sent reminder_sent_at
    reminder_paused_at reminder_error reminder_twilio_sid reminder_sms_fallback_claimed_at
    paid_at created_at
  )
  # Offsets from the original send. 14 weeks is later than 30 days, so it is last.
  @reminder_offsets [
    24 * 60 * 60,
    48 * 60 * 60,
    72 * 60 * 60,
    7 * 24 * 60 * 60,
    30 * 24 * 60 * 60,
    14 * 7 * 24 * 60 * 60
  ]
  @min_minor 100
  @max_minor 2_147_483_647
  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @token ~r/^[0-9a-f]{64}$/
  @receipt_email "payments@tryinstaclean.com"

  def list(user_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, result} <-
           Repo.query("#{select_sql()} ORDER BY created_at DESC LIMIT 30", []) do
      {:ok, %{"requests" => Enum.map(result.rows, &admin_json(row_map(&1)))}}
    else
      :error ->
        {:error, :invalid_request}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, error} ->
        database_error(error)
    end
  end

  def create(user_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, input} <- validate(params),
         {:ok, customer_id, email} <-
           resolve_customer(input.customer_user_id, input.phone, input.email) do
      insert_and_send(admin_uid, %{input | customer_user_id: customer_id, email: email})
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def public_show(token) when is_binary(token) do
    if token_ok?(token) do
      case fetch_token(token) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, row} -> {:ok, public_json(row)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def public_show(_), do: {:error, :not_found}

  def checkout(token, params) when is_binary(token) and is_map(params) do
    if token_ok?(token) do
      with {:ok, email} <- optional_email(params["email"] || params[:email]) do
        Repo.transaction(fn ->
          case lock_token(token) do
            nil ->
              Repo.rollback(:not_found)

            %{"status" => "paid"} ->
              Repo.rollback(:already_paid)

            row ->
              row = maybe_store_email(row, email)

              case ensure_authorization(row) do
                {:ok, checkout} -> checkout
                # A rotated reference must commit even when initialization failed.
                {:error, reason} -> {:checkout_error, reason}
              end
          end
        end)
        |> normalize_transaction()
        |> unwrap_checkout_error()
      end
    else
      {:error, :not_found}
    end
  end

  def checkout(_, _), do: {:error, :not_found}

  def verify(token, params) when is_binary(token) and is_map(params) do
    reference = params["reference"] || params[:reference]

    if token_ok?(token) and is_binary(reference) and String.trim(reference) != "" do
      Repo.transaction(fn ->
        case lock_token(token) do
          nil ->
            Repo.rollback(:not_found)

          %{"status" => "paid", "paystack_reference" => stored} = row ->
            submitted = String.trim(reference)

            if stored == submitted or previous_reference?(row["id"], submitted),
              do: public_json(row),
              else: Repo.rollback(:not_found)

          %{"paystack_reference" => stored} = row ->
            submitted = String.trim(reference)

            if stored != submitted and not previous_reference?(row["id"], submitted) do
              Repo.rollback(:not_found)
            else
              case confirm_paid(row, submitted) do
                {:ok, paid} -> public_json(paid)
                {:error, reason} -> Repo.rollback(reason)
              end
            end
        end
      end)
      |> normalize_transaction()
    else
      {:error, :not_found}
    end
  end

  def verify(_, _), do: {:error, :not_found}

  @doc """
  Settles a Paystack `charge.success` whose reference belongs to a payment
  request rather than a booking attempt.

  Returns `:unknown` when this reference is not a payment request, including
  when the table has not been created yet.
  """
  def settle_charge(%{reference: reference} = event) when is_binary(reference) do
    if table?("public.direct_payment_requests") do
      case Repo.query(
             "#{select_sql()} WHERE paystack_reference = $1 FOR UPDATE",
             [reference]
           ) do
        {:ok, %{rows: []}} -> settle_previous_reference(reference, event)
        {:ok, %{rows: [row]}} -> apply_webhook(row_map(row), event)
        {:error, error} -> database_error(error)
      end
    else
      :unknown
    end
  end

  def settle_charge(_), do: :unknown

  @doc "Reconcile an authenticated Twilio delivery callback. A failed WhatsApp send triggers SMS once."
  def payment_status_callback(token, params, signature) when is_map(params) do
    base = Application.get_env(:mithril, :twilio_payment_status_callback_url)
    auth_token = Application.get_env(:mithril, :twilio_auth_token)

    with true <- token_ok?(token),
         true <- is_binary(base) and String.starts_with?(base, "https://"),
         true <-
           TwilioSignature.valid?(
             params,
             signature,
             auth_token,
             String.trim_trailing(base, "/") <> "/" <> token
           ) do
      status = params["MessageStatus"] || params["SmsStatus"]
      sid = params["MessageSid"] || params["SmsSid"]

      if status in ["failed", "undelivered"] and is_binary(sid) and sid != "" do
        case send_failed_reminder_sms(token, sid) do
          :not_reminder -> send_failed_whatsapp_sms(token, sid)
          result -> result
        end
      else
        :ok
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  # A reminder has its own delivery identity and SMS fallback claim. Never
  # treat a reminder callback as a failure of the original payment link.
  defp send_failed_reminder_sms(token, sid) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET reminder_sms_fallback_claimed_at = now(),
               reminder_error = 'whatsapp_undelivered', updated_at = now()
           WHERE public_token = $1 AND reminder_twilio_sid = $2
             AND status = 'unpaid' AND reminder_sms_fallback_claimed_at IS NULL
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [token, sid]
         ) do
      {:ok, %{rows: [row]}} ->
        request = row_map(row)

        case SMS.send_message(request["phone_e164"], reminder_sms_body(request)) do
          :ok ->
            Repo.query(
              "UPDATE public.direct_payment_requests SET reminder_error = NULL, updated_at = now() WHERE id = $1 AND reminder_twilio_sid = $2",
              [request["id"], sid]
            )

            :ok

          {:error, reason} ->
            Repo.query(
              "UPDATE public.direct_payment_requests SET reminder_error = $3, updated_at = now() WHERE id = $1 AND reminder_twilio_sid = $2",
              [request["id"], sid, "sms_fallback_#{reason}"]
            )

            :ok
        end

      {:ok, %{rows: []}} ->
        case Repo.query(
               "SELECT 1 FROM public.direct_payment_requests WHERE public_token = $1 AND reminder_twilio_sid = $2",
               [token, sid]
             ) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, _} -> :not_reminder
          {:error, error} -> database_error(error)
        end

      {:error, error} ->
        database_error(error)
    end
  end

  defp send_failed_whatsapp_sms(token, sid) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET sms_fallback_claimed_at = now(), updated_at = now()
           WHERE public_token = $1 AND status = 'unpaid'
             AND sms_fallback_claimed_at IS NULL
             AND (twilio_message_sid IS NULL OR twilio_message_sid = $2)
             AND delivery_claimed_at IS NOT NULL
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [token, sid]
         ) do
      {:ok, %{rows: [row]}} ->
        request = row_map(row)

        case sms(request) do
          {:ok, "sms", nil} ->
            _ =
              Repo.query(
                """
                UPDATE public.direct_payment_requests
                SET channel = 'sms', sent_at = now(), delivery_error = NULL, updated_at = now()
                WHERE id = $1
                """,
                [request["id"]]
              )

            :ok

          {:error, :sms_not_configured} ->
            # No provider call was made. Release only this definite non-send so
            # a retried signed Twilio callback can deliver after configuration.
            _ =
              Repo.query(
                """
                UPDATE public.direct_payment_requests
                SET sms_fallback_claimed_at = NULL,
                    delivery_error = 'sms_fallback_sms_not_configured', updated_at = now()
                WHERE id = $1
                """,
                [request["id"]]
              )

            {:error, :sms_retryable}

          {:error, reason} ->
            _ =
              Repo.query(
                """
                UPDATE public.direct_payment_requests
                SET delivery_error = $2, updated_at = now()
                WHERE id = $1
                """,
                [request["id"], "sms_fallback_" <> Atom.to_string(reason)]
              )

            :ok
        end

      {:ok, %{rows: []}} ->
        :ok

      {:error, error} ->
        database_error(error)
    end
  end

  defp settle_previous_reference(reference, event) do
    columns = Enum.map_join(@columns, ", ", &"request.#{&1}")

    case Repo.query(
           """
           SELECT #{columns}
           FROM public.direct_payment_requests request
           JOIN public.direct_payment_request_references old
             ON old.payment_request_id = request.id
           WHERE old.reference = $1
           FOR UPDATE OF request
           """,
           [reference]
         ) do
      {:ok, %{rows: [row]}} -> apply_webhook(row_map(row), event)
      {:ok, %{rows: []}} -> :unknown
      {:error, error} -> database_error(error)
    end
  end

  @doc "Send the scheduled reminder when the request is still unpaid."
  def deliver_unpaid_reminder(id) when is_binary(id) do
    with {:ok, uuid} <- dump_uuid(id),
         {:ok, row} <- fetch_row(uuid) do
      deliver_unpaid_reminder(id, row["reminders_sent"] || 0)
    else
      :error -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def deliver_unpaid_reminder(id, step) when is_binary(id) and is_integer(step) do
    deliver_step(id, step, false)
  end

  def deliver_unpaid_reminder(_, _), do: :ok

  def pause_reminders(user_id, id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, uuid} <- dump_uuid(id) do
      case Repo.query(
             """
             UPDATE public.direct_payment_requests
             SET reminder_paused_at = COALESCE(reminder_paused_at, now()), updated_at = now()
             WHERE id = $1 AND remind_if_unpaid AND status = 'unpaid'
             RETURNING #{Enum.join(@columns, ", ")}
             """,
             [uuid]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, admin_json(row_map(row))}
        {:ok, %{rows: []}} -> reminder_action_error(uuid)
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_reminders(user_id, id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, uuid} <- dump_uuid(id) do
      case Repo.query(
             """
             UPDATE public.direct_payment_requests
             SET reminder_paused_at = NULL, updated_at = now()
             WHERE id = $1
               AND remind_if_unpaid
               AND status = 'unpaid'
               AND reminder_paused_at IS NOT NULL
             RETURNING #{Enum.join(@columns, ", ")}
             """,
             [uuid]
           ) do
        {:ok, %{rows: [row]}} ->
          mapped = row_map(row)
          schedule_unpaid_reminder(mapped, 5)
          {:ok, admin_json(mapped)}

        {:ok, %{rows: []}} ->
          resume_unchanged(uuid)

        {:error, error} ->
          database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Turn on the unpaid reminder sequence for a request sent before reminders existed."
  def enable_reminders(user_id, id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, uuid} <- dump_uuid(id) do
      case Repo.query(
             """
             UPDATE public.direct_payment_requests
             SET remind_if_unpaid = true, updated_at = now()
             WHERE id = $1
               AND status = 'unpaid'
               AND sent_at IS NOT NULL
               AND NOT remind_if_unpaid
             RETURNING #{Enum.join(@columns, ", ")}
             """,
             [uuid]
           ) do
        {:ok, %{rows: [row]}} ->
          mapped = row_map(row)
          schedule_unpaid_reminder(mapped)
          {:ok, admin_json(mapped)}

        {:ok, %{rows: []}} ->
          enable_unchanged(uuid)

        {:error, error} ->
          database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def retry_message(user_id, id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, uuid} <- dump_uuid(id),
         {:ok, row} <- fetch_row(uuid) do
      cond do
        row["status"] == "paid" ->
          {:error, :already_paid}

        is_nil(row["sent_at"]) ->
          # A provider timeout has an unknown outcome; only an explicit
          # definite non-send may be retried, and the claim is cleared there.
          if is_nil(row["delivery_claimed_at"]) and is_binary(row["delivery_error"]) do
            send_fetched(uuid)
          else
            {:error, :reminder_in_progress}
          end

        is_binary(row["reminder_error"]) and is_binary(row["reminder_twilio_sid"]) ->
          retry_reminder_sms(row)

        is_binary(row["reminder_error"]) ->
          step = row["reminders_sent"] || 0

          case deliver_step(id, step, true) do
            :ok -> present_row(uuid)
            {:snooze, _} -> {:error, :reminder_in_progress}
            {:error, reason} -> {:error, reason}
          end

        true ->
          {:error, :nothing_to_retry}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def sms_body(request) when is_map(request) do
    url = pay_url(request["public_token"])
    amount = DirectAdminInvoices.money(request["amount_minor"])
    suffix = ". Tap here to pay: #{url}"
    prefix = "Instaclean: #{request["customer_name"]}, #{amount} for "
    room = 300 - String.length(prefix) - String.length(suffix)

    detail =
      if room >= 8 do
        request["description"]
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, room)
      else
        "your bill"
      end

    prefix <> detail <> suffix
  end

  def reminder_sms_body(request) when is_map(request) do
    url = pay_url(request["public_token"])
    amount = DirectAdminInvoices.money(request["amount_minor"])
    suffix = " is still unpaid. Tap here to pay: #{url}"
    prefix = "Instaclean reminder: #{request["customer_name"]}, #{amount} for "
    room = 300 - String.length(prefix) - String.length(suffix)

    detail =
      if room >= 8 do
        request["description"]
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, room)
      else
        "your bill"
      end

    prefix <> detail <> suffix
  end

  defp insert_and_send(admin_uid, input) do
    id = Ecto.UUID.generate()
    token = random_token()
    reference = "icpr-" <> random_hex(12)

    params = [
      dump!(id),
      token,
      dump_optional(input.customer_user_id),
      input.customer_name,
      input.phone,
      input.email,
      input.description,
      input.amount_minor,
      reference,
      admin_uid,
      dump!(input.idempotency_key),
      input.remind_if_unpaid
    ]

    case Repo.query(
           """
           INSERT INTO public.direct_payment_requests (
             id, public_token, customer_user_id, customer_name, phone_e164, email,
             description, amount_minor, paystack_reference, created_by, idempotency_key,
             remind_if_unpaid
           ) VALUES (
             $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
           )
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           params
         ) do
      {:ok, %{rows: [row]}} ->
        send_and_present(row)

      {:error, %Postgrex.Error{postgres: %{constraint: "direct_payment_requests_idempotency"}}} ->
        replay(admin_uid, input.idempotency_key)

      {:error, error} ->
        database_error(error)
    end
  end

  defp replay(admin_uid, idempotency_key) do
    case Repo.query(
           """
           #{select_sql()}
           WHERE created_by = $1 AND idempotency_key = $2
           """,
           [admin_uid, dump!(idempotency_key)]
         ) do
      {:ok, %{rows: [row]}} ->
        mapped = row_map(row)
        if mapped["sent_at"], do: schedule_unpaid_reminder(mapped)
        if mapped["sent_at"], do: {:ok, admin_json(mapped)}, else: send_and_present(row)

      {:ok, %{rows: []}} ->
        {:error, :invalid_request}

      {:error, error} ->
        database_error(error)
    end
  end

  defp send_and_present(row) do
    send_mapped(row_map(row))
  end

  defp send_mapped(request) do
    case claim_delivery(request["id"]) do
      {:ok, nil} ->
        {:ok, admin_json(request)}

      {:ok, claimed} ->
        deliver_claimed(claimed)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_claimed(request) do
    case deliver(request) do
      {:ok, channel, message_sid} ->
        case mark_sent(request["id"], channel, message_sid) do
          {:ok, updated} ->
            schedule_unpaid_reminder(updated)
            {:ok, admin_json(updated)}

          {:error, _} ->
            merged =
              Map.merge(request, %{"channel" => channel, "sent_at" => DateTime.utc_now()})

            schedule_unpaid_reminder(merged)
            {:ok, admin_json(merged)}
        end

      {:error, reason} ->
        _ =
          if reason in [:sms_not_configured, :invalid_phone] do
            # Neither provider accepted the message. A replay may safely
            # claim delivery again once configuration or the phone is fixed.
            release_unsent_delivery(request["id"], reason)
          else
            # An unknown provider outcome must not create duplicate sends.
            mark_delivery_error(request["id"], reason)
          end

        {:ok, admin_json(Map.put(request, "delivery_error", Atom.to_string(reason)))}
    end
  end

  defp claim_delivery(id) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET delivery_claimed_at = now(), updated_at = now()
           WHERE id = $1 AND sent_at IS NULL AND delivery_claimed_at IS NULL
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, error} -> database_error(error)
    end
  end

  defp deliver(request) do
    case whatsapp(request) do
      {:ok, sid} ->
        {:ok, "whatsapp", sid}

      {:error, :twilio_unavailable} ->
        {:error, :delivery_unknown}

      _other ->
        sms(request)
    end
  end

  defp whatsapp(request) do
    with {:ok, callback_url} <- payment_callback_url(request["public_token"]),
         {:ok, sid} <- PaymentTemplate.ensure(),
         {:ok, from} <- admin_from() do
      Outbound.send_content(
        "whatsapp:" <> request["phone_e164"],
        from,
        sid,
        PaymentTemplate.variables(%{
          "customerName" => request["customer_name"],
          "description" => request["description"],
          "amountLabel" => DirectAdminInvoices.money(request["amount_minor"]),
          "publicToken" => request["public_token"]
        }),
        callback_url
      )
    end
  end

  defp payment_callback_url(token) do
    base = Application.get_env(:mithril, :twilio_payment_status_callback_url)

    if is_binary(base) and String.starts_with?(base, "https://") do
      {:ok, String.trim_trailing(base, "/") <> "/" <> token}
    else
      {:error, :twilio_not_configured}
    end
  end

  defp sms(request) do
    case SMS.send_message(request["phone_e164"], sms_body(request)) do
      :ok -> {:ok, "sms", nil}
      {:error, :sms_not_configured} -> {:error, :sms_not_configured}
      {:error, :invalid_phone} -> {:error, :invalid_phone}
      {:error, _} -> {:error, :sms_delivery_failed}
    end
  end

  defp admin_from do
    raw =
      Application.get_env(:mithril, :twilio_whatsapp_admin_from) ||
        Application.get_env(:mithril, :twilio_whatsapp_from)

    first =
      raw
      |> to_string()
      |> String.split(",")
      |> List.first()
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^whatsapp:/i, "")

    case Phone.normalize(first) do
      {:ok, e164} -> {:ok, "whatsapp:" <> e164}
      :error -> {:error, :twilio_not_configured}
    end
  end

  defp ensure_authorization(row) do
    # Paystack checkout sessions expire. Reusing a stored authorization URL
    # shows "Session timeout exceeded", so every Pay click starts a new one.
    # The public /pay link stays the same. An older session can still settle.
    row = refresh_checkout(row)
    email = row["email"] || @receipt_email

    attrs = %{
      email: email,
      amount: row["amount_minor"],
      currency: row["currency"] || "GHS",
      reference: row["paystack_reference"],
      callback_url: pay_url(row["public_token"]),
      metadata: %{
        "payment_request_id" => uuid_string(row["id"]),
        "public_token" => row["public_token"],
        "kind" => "direct_payment_request"
      }
    }

    case initialize_payment(attrs) do
      {:ok, %{authorization_url: authorization_url, reference: reference}} ->
        if paystack_checkout_url?(authorization_url) and reference == row["paystack_reference"] do
          case store_authorization(row["id"], authorization_url) do
            {:ok, updated} ->
              {:ok, checkout_json(updated, authorization_url)}

            {:error, _} ->
              {:ok,
               checkout_json(
                 Map.put(row, "authorization_url", authorization_url),
                 authorization_url
               )}
          end
        else
          {:error, :payment_not_configured}
        end

      {:error, :payment_not_configured} ->
        {:error, :payment_not_configured}

      {:error, reason} ->
        Logger.warning("payment request checkout failed #{inspect(reason)}")
        # The provider may have accepted the first request before its HTTP
        # response was lost. Preserve that reference for late webhooks, then
        # issue a fresh one for the next public checkout attempt.
        _ = rotate_reference(row)
        {:error, :payment_unavailable}
    end
  end

  defp refresh_checkout(row) do
    if paystack_checkout_url?(row["authorization_url"]) do
      case rotate_reference(row) do
        {:ok, reference} -> %{row | "paystack_reference" => reference, "authorization_url" => nil}
        {:error, _} -> row
      end
    else
      row
    end
  end

  defp rotate_reference(row) do
    new_reference = "icpr-" <> random_hex(12)

    with {:ok, _} <-
           Repo.query(
             """
             INSERT INTO public.direct_payment_request_references
               (reference, payment_request_id)
             VALUES ($1, $2)
             ON CONFLICT (reference) DO NOTHING
             """,
             [row["paystack_reference"], row["id"]]
           ),
         {:ok, %{rows: [[_]]}} <-
           Repo.query(
             """
             UPDATE public.direct_payment_requests
             SET paystack_reference = $2, authorization_url = NULL, updated_at = now()
             WHERE id = $1 AND paystack_reference = $3 AND status = 'unpaid'
             RETURNING id
             """,
             [row["id"], new_reference, row["paystack_reference"]]
           ) do
      {:ok, new_reference}
    else
      _ -> {:error, :payment_conflict}
    end
  end

  defp previous_reference?(id, reference) do
    case Repo.query(
           """
           SELECT 1 FROM public.direct_payment_request_references
           WHERE payment_request_id = $1 AND reference = $2
           LIMIT 1
           """,
           [id, reference]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp initialize_payment(attrs) do
    Paystack.initialize(put_payment_secret(attrs))
  end

  defp verify_payment(reference) do
    case payment_request_secret() do
      nil -> Paystack.verify(reference)
      secret -> Paystack.verify(reference, secret)
    end
  end

  defp put_payment_secret(attrs) do
    case payment_request_secret() do
      nil -> attrs
      secret -> Map.put(attrs, :paystack_secret, secret)
    end
  end

  defp payment_request_secret do
    case Application.get_env(:mithril, :paystack_payment_request_secret_key) do
      secret when is_binary(secret) ->
        secret = String.trim(secret)
        if secret == "", do: nil, else: secret

      _ ->
        nil
    end
  end

  defp confirm_paid(row, reference) do
    case verify_payment(reference) do
      {:ok, receipt} ->
        cond do
          receipt_value(receipt, :status) != "success" ->
            {:error, :payment_incomplete}

          receipt_value(receipt, :amount) != row["amount_minor"] ->
            {:error, :amount_mismatch}

          receipt_value(receipt, :currency) != (row["currency"] || "GHS") ->
            {:error, :amount_mismatch}

          receipt_value(receipt, :reference) not in [nil, reference] ->
            {:error, :amount_mismatch}

          true ->
            mark_paid(row["id"])
        end

      {:error, :not_found} ->
        {:error, :payment_incomplete}

      {:error, :payment_not_configured} ->
        {:error, :payment_not_configured}

      {:error, reason} ->
        Logger.warning("payment request verify failed #{inspect(reason)}")
        {:error, :payment_unavailable}
    end
  end

  defp apply_webhook(row, event) do
    amount = Map.get(event, :amount_minor)
    currency = Map.get(event, :currency) || "GHS"
    status = Map.get(event, :status)

    cond do
      row["status"] == "paid" and amount == row["amount_minor"] and currency == row["currency"] ->
        {:ok, %{already_paid: true, reference: row["paystack_reference"]}}

      status not in [nil, "success"] ->
        {:ok,
         %{ignored: true, reason: "payment_incomplete", reference: row["paystack_reference"]}}

      amount != row["amount_minor"] or currency != row["currency"] ->
        {:error, :amount_mismatch}

      true ->
        case mark_paid(row["id"]) do
          {:ok, _} -> {:ok, %{settled: true, reference: row["paystack_reference"]}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_store_email(row, nil), do: row

  defp maybe_store_email(%{"email" => email} = row, email), do: row

  defp maybe_store_email(row, email) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET email = $2, updated_at = now()
           WHERE id = $1 AND status = 'unpaid'
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [row["id"], email]
         ) do
      {:ok, %{rows: [updated]}} -> row_map(updated)
      _ -> Map.put(row, "email", email)
    end
  end

  defp store_authorization(id, url) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET authorization_url = $2, updated_at = now()
           WHERE id = $1 AND status = 'unpaid'
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id, url]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:error, :payment_conflict}
      {:error, error} -> database_error(error)
    end
  end

  defp mark_sent(id, channel, sid) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET channel = CASE WHEN sms_fallback_claimed_at IS NULL THEN $2 ELSE channel END,
               twilio_message_sid = $3,
               sent_at = now(),
               delivery_error = CASE WHEN sms_fallback_claimed_at IS NULL THEN NULL ELSE delivery_error END,
               updated_at = now()
           WHERE id = $1
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id, channel, sid]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:error, error} -> database_error(error)
    end
  end

  defp mark_delivery_error(id, reason) do
    Repo.query(
      """
      UPDATE public.direct_payment_requests
      SET delivery_error = $2, updated_at = now()
      WHERE id = $1 AND sent_at IS NULL
      """,
      [id, Atom.to_string(reason)]
    )
  end

  defp deliver_step(id, step, ignore_pause) when is_binary(id) and is_integer(step) do
    with {:ok, uuid} <- dump_uuid(id),
         {:ok, request} <- claim_reminder(uuid, step, ignore_pause) do
      case request do
        nil -> reminder_wait(uuid, step)
        request -> send_reminder(request, step)
      end
    else
      :error -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_unpaid_reminder(row, minimum_seconds \\ 1) do
    step = row["reminders_sent"] || 0
    sent_at = row["sent_at"]

    cond do
      row["remind_if_unpaid"] != true -> :ok
      not is_nil(row["reminder_paused_at"]) -> :ok
      is_nil(sent_at) -> :ok
      step < 0 or step >= length(@reminder_offsets) -> :ok
      true -> enqueue_reminder(row["id"], step, reminder_delay(sent_at, step, minimum_seconds))
    end
  end

  defp enqueue_reminder(id, step, delay_seconds) do
    if Application.get_env(:mithril, :start_oban, true) do
      job =
        PaymentRequestReminder.new(
          %{"payment_request_id" => uuid_string(id), "step" => step},
          schedule_in: {max(delay_seconds, 1), :second}
        )

      case Oban.insert(job) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.error("payment request reminder enqueue failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp reminder_delay(sent_at, step, minimum_seconds) do
    target = DateTime.add(coerce_datetime(sent_at), Enum.at(@reminder_offsets, step), :second)
    delay = DateTime.diff(target, DateTime.utc_now(), :second)
    max(delay, minimum_seconds)
  end

  defp reminder_wait(id, step) do
    case Repo.query(
           """
           SELECT 1
           FROM public.direct_payment_requests
           WHERE id = $1
             AND remind_if_unpaid
             AND status = 'unpaid'
             AND reminder_paused_at IS NULL
             AND reminders_sent = $2
             AND reminder_claimed_at IS NOT NULL
           """,
           [id, step]
         ) do
      {:ok, %{num_rows: 1}} -> {:snooze, 660}
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp claim_reminder(id, step, ignore_pause) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET reminder_claimed_at = now(), updated_at = now()
           WHERE id = $1
             AND remind_if_unpaid
             AND status = 'unpaid'
             AND sent_at IS NOT NULL
             AND reminders_sent = $2
             AND ($3 OR reminder_paused_at IS NULL)
             AND (
               reminder_claimed_at IS NULL
               OR reminder_claimed_at < now() - interval '10 minutes'
             )
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id, step, ignore_pause]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, error} -> database_error(error)
    end
  end

  defp send_reminder(request, step) do
    case deliver_reminder_message(request) do
      {:ok, _channel, sid} ->
        case mark_reminder_sent(request["id"], step, sid) do
          {:ok, nil} ->
            :ok

          {:ok, _updated} ->
            :ok

          {:error, reason} ->
            _ = release_reminder_claim(request["id"], step)
            {:error, reason}
        end

      {:error, :twilio_unavailable} ->
        _ = record_reminder_failure(request["id"], step, "delivery_unknown")
        {:error, :delivery_unknown}

      {:error, reason} ->
        _ = record_reminder_failure(request["id"], step, Atom.to_string(reason))
        {:error, reason}
    end
  end

  defp deliver_reminder_message(request) do
    case whatsapp(request) do
      {:ok, sid} ->
        {:ok, "whatsapp", sid}

      {:error, :twilio_unavailable} ->
        {:error, :twilio_unavailable}

      _other ->
        case SMS.send_message(request["phone_e164"], reminder_sms_body(request)) do
          :ok -> {:ok, "sms", nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp mark_reminder_sent(id, step, sid) do
    Repo.transaction(fn ->
      case Repo.query(
             """
             UPDATE public.direct_payment_requests
             SET reminders_sent = reminders_sent + 1,
                 reminder_sent_at = now(),
                 reminder_twilio_sid = $3,
                 reminder_sms_fallback_claimed_at = NULL,
                 reminder_claimed_at = NULL,
                 reminder_error = NULL,
                 updated_at = now()
             WHERE id = $1 AND reminders_sent = $2
             RETURNING #{Enum.join(@columns, ", ")}
             """,
             [id, step, sid]
           ) do
        {:ok, %{rows: [row]}} ->
          updated = row_map(row)
          next_step = updated["reminders_sent"]

          if updated["remind_if_unpaid"] and is_nil(updated["reminder_paused_at"]) and
               next_step < length(@reminder_offsets) and
               Application.get_env(:mithril, :start_oban, true) do
            job =
              PaymentRequestReminder.new(
                %{"payment_request_id" => uuid_string(id), "step" => next_step},
                schedule_in:
                  {reminder_delay(updated["sent_at"], next_step, 24 * 60 * 60), :second}
              )

            case Oban.insert(job) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          updated

        {:ok, %{rows: []}} ->
          nil

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> database_error(error)
    end
  end

  defp record_reminder_failure(id, step, reason) do
    Repo.query(
      """
      UPDATE public.direct_payment_requests
      SET reminder_claimed_at = NULL, reminder_error = $3, updated_at = now()
      WHERE id = $1 AND reminders_sent = $2
      """,
      [id, step, reason]
    )
  end

  defp release_reminder_claim(id, step) do
    Repo.query(
      """
      UPDATE public.direct_payment_requests
      SET reminder_claimed_at = NULL, updated_at = now()
      WHERE id = $1 AND reminders_sent = $2
      """,
      [id, step]
    )
  end

  defp retry_reminder_sms(row) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET reminder_error = 'sms_retry_in_progress', updated_at = now()
           WHERE id = $1 AND reminder_twilio_sid = $2
             AND reminder_error NOT IN ('sms_retry_in_progress', 'delivery_unknown')
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [row["id"], row["reminder_twilio_sid"]]
         ) do
      {:ok, %{rows: []}} ->
        {:error, :reminder_in_progress}

      {:ok, %{rows: [_]}} ->
        case SMS.send_message(row["phone_e164"], reminder_sms_body(row)) do
          :ok ->
            Repo.query(
              "UPDATE public.direct_payment_requests SET reminder_error = NULL WHERE id = $1",
              [row["id"]]
            )

            present_row(row["id"])

          {:error, reason} ->
            Repo.query(
              "UPDATE public.direct_payment_requests SET reminder_error = $2 WHERE id = $1",
              [row["id"], "sms_fallback_#{reason}"]
            )

            {:error, reason}
        end

      {:error, error} ->
        database_error(error)
    end
  end

  defp send_fetched(id) do
    case fetch_row(id) do
      {:ok, row} -> send_mapped(row)
      {:error, reason} -> {:error, reason}
    end
  end

  defp present_row(id) do
    case fetch_row(id) do
      {:ok, row} -> {:ok, admin_json(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_unchanged(id) do
    case fetch_row(id) do
      {:ok,
       %{"remind_if_unpaid" => true, "status" => "unpaid", "reminder_paused_at" => nil} = row} ->
        {:ok, admin_json(row)}

      other ->
        reminder_action_result(other)
    end
  end

  defp enable_unchanged(id) do
    case fetch_row(id) do
      {:ok, %{"status" => "paid"}} ->
        {:error, :already_paid}

      {:ok, %{"sent_at" => nil}} ->
        {:error, :not_sent}

      {:ok, %{"remind_if_unpaid" => true} = row} ->
        {:ok, admin_json(row)}

      {:ok, _} ->
        {:error, :not_remindable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reminder_action_error(id) do
    reminder_action_result(fetch_row(id))
  end

  defp reminder_action_result({:ok, %{"status" => "paid"}}), do: {:error, :already_paid}

  defp reminder_action_result({:ok, %{"remind_if_unpaid" => true}}),
    do: {:error, :invalid_request}

  defp reminder_action_result({:ok, _}), do: {:error, :not_remindable}
  defp reminder_action_result({:error, reason}), do: {:error, reason}

  defp fetch_row(id) do
    case Repo.query("#{select_sql()} WHERE id = $1", [id]) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp coerce_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp coerce_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _} -> DateTime.truncate(parsed, :second)
      _ -> DateTime.utc_now()
    end
  end

  defp release_unsent_delivery(id, reason) do
    Repo.query(
      """
      UPDATE public.direct_payment_requests
      SET delivery_claimed_at = NULL, delivery_error = $2, updated_at = now()
      WHERE id = $1 AND sent_at IS NULL AND twilio_message_sid IS NULL
      """,
      [id, Atom.to_string(reason)]
    )
  end

  defp mark_paid(id) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET status = 'paid', paid_at = COALESCE(paid_at, now()), updated_at = now()
           WHERE id = $1 AND status = 'unpaid'
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id]
         ) do
      {:ok, %{rows: [row]}} ->
        {:ok, row_map(row)}

      {:ok, %{rows: []}} ->
        case fetch_id(id) do
          {:ok, %{"status" => "paid"} = row} -> {:ok, row}
          _ -> {:error, :payment_conflict}
        end

      {:error, error} ->
        database_error(error)
    end
  end

  defp fetch_token(token) do
    case Repo.query("#{select_sql()} WHERE public_token = $1", [token]) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, error} -> database_error(error)
    end
  end

  defp fetch_id(id) do
    case Repo.query("#{select_sql()} WHERE id = $1", [id]) do
      {:ok, %{rows: [row]}} -> {:ok, row_map(row)}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, error} -> database_error(error)
    end
  end

  defp lock_token(token) do
    case Repo.query("#{select_sql()} WHERE public_token = $1 FOR UPDATE", [token]) do
      {:ok, %{rows: [row]}} -> row_map(row)
      _ -> nil
    end
  end

  defp resolve_customer(nil, phone, email) do
    case Repo.query(
           "SELECT id, email FROM public.users WHERE phone = $1 LIMIT 2",
           [phone]
         ) do
      {:ok, %{rows: [[id, stored_email]]}} ->
        {:ok, uuid_string(id), email || clean_email(stored_email)}

      {:ok, _} ->
        {:ok, nil, email}

      {:error, error} ->
        database_error(error)
    end
  end

  defp resolve_customer(customer_id, _phone, email) do
    case Repo.query("SELECT email FROM public.users WHERE id = $1", [dump!(customer_id)]) do
      {:ok, %{rows: [[stored_email]]}} ->
        {:ok, customer_id, email || clean_email(stored_email)}

      {:ok, %{rows: []}} ->
        {:error, :customer_not_found}

      {:error, error} ->
        database_error(error)
    end
  end

  defp validate(params) do
    with {:ok, name} <- required_text(params["customerName"] || params[:customerName], 160),
         {:ok, phone} <- required_phone(params["phone"] || params[:phone]),
         {:ok, description} <- required_text(params["description"] || params[:description], 160),
         {:ok, amount} <- amount(params["amountMinor"] || params[:amountMinor]),
         {:ok, customer_id} <- optional_uuid(params["customerUserId"] || params[:customerUserId]),
         {:ok, email} <- optional_email(params["email"] || params[:email]),
         {:ok, key} <- required_uuid(params["idempotencyKey"] || params[:idempotencyKey]),
         {:ok, remind} <- optional_flag(flag_value(params, "remindIfUnpaid")) do
      {:ok,
       %{
         customer_name: name,
         phone: phone,
         description: description,
         amount_minor: amount,
         customer_user_id: customer_id,
         email: email,
         idempotency_key: key,
         remind_if_unpaid: remind
       }}
    end
  end

  defp required_text(value, max) when is_binary(value) do
    text = String.trim(value)

    if text != "" and String.length(text) <= max,
      do: {:ok, text},
      else: {:error, :invalid_request}
  end

  defp required_text(_, _), do: {:error, :invalid_request}

  defp required_phone(value) when is_binary(value) do
    case Phone.normalize(value) do
      {:ok, e164} -> {:ok, e164}
      :error -> {:error, :invalid_phone}
    end
  end

  defp required_phone(_), do: {:error, :invalid_phone}

  defp amount(value) when is_integer(value) and value >= @min_minor and value <= @max_minor,
    do: {:ok, value}

  defp amount(_), do: {:error, :invalid_request}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}

  defp optional_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp optional_uuid(_), do: {:error, :invalid_request}

  defp required_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp required_uuid(_), do: {:error, :invalid_request}

  defp flag_value(params, "remindIfUnpaid") do
    cond do
      Map.has_key?(params, "remindIfUnpaid") -> params["remindIfUnpaid"]
      Map.has_key?(params, :remindIfUnpaid) -> params[:remindIfUnpaid]
      true -> false
    end
  end

  defp optional_flag(value) when value in [true, false], do: {:ok, value}
  defp optional_flag(nil), do: {:ok, false}
  defp optional_flag(_), do: {:error, :invalid_request}

  defp optional_email(nil), do: {:ok, nil}
  defp optional_email(""), do: {:ok, nil}

  defp optional_email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()

    cond do
      email == "" -> {:ok, nil}
      String.length(email) <= 200 and String.match?(email, @email) -> {:ok, email}
      true -> {:error, :invalid_email}
    end
  end

  defp optional_email(_), do: {:error, :invalid_email}

  defp clean_email(value) when is_binary(value) do
    case optional_email(value) do
      {:ok, email} -> email
      _ -> nil
    end
  end

  defp clean_email(_), do: nil

  defp next_reminder_at(row) do
    step = row["reminders_sent"] || 0
    sent_at = row["sent_at"]

    cond do
      row["remind_if_unpaid"] != true ->
        nil

      row["status"] == "paid" ->
        nil

      is_nil(sent_at) or not is_integer(step) ->
        nil

      step < 0 or step >= length(@reminder_offsets) ->
        nil

      true ->
        sent_at
        |> coerce_datetime()
        |> DateTime.add(Enum.at(@reminder_offsets, step), :second)
        |> timestamp()
    end
  end

  defp admin_json(row) do
    %{
      "id" => uuid_string(row["id"]),
      "publicToken" => row["public_token"],
      "payUrl" => pay_url(row["public_token"]),
      "customerUserId" => uuid_string(row["customer_user_id"]),
      "customerName" => row["customer_name"],
      "phone" => row["phone_e164"],
      "email" => row["email"],
      "description" => row["description"],
      "amountMinor" => row["amount_minor"],
      "currency" => row["currency"] || "GHS",
      "status" => row["status"],
      "channel" => row["channel"],
      "sent" => not is_nil(row["sent_at"]),
      "deliveryError" => row["delivery_error"],
      "sentAt" => timestamp(row["sent_at"]),
      "paidAt" => timestamp(row["paid_at"]),
      "createdAt" => timestamp(row["created_at"]),
      "remindIfUnpaid" => row["remind_if_unpaid"] == true,
      "remindersSent" => row["reminders_sent"] || 0,
      "reminderSentAt" => timestamp(row["reminder_sent_at"]),
      "reminderPaused" => not is_nil(row["reminder_paused_at"]),
      "nextReminderAt" => next_reminder_at(row),
      "reminderError" => row["reminder_error"]
    }
  end

  defp public_json(row) do
    %{
      "customerName" => row["customer_name"],
      "description" => row["description"],
      "amountMinor" => row["amount_minor"],
      "currency" => row["currency"] || "GHS",
      "status" => row["status"],
      "paidAt" => timestamp(row["paid_at"])
    }
  end

  defp checkout_json(row, url) do
    %{
      "authorizationUrl" => url,
      "reference" => row["paystack_reference"],
      "amountMinor" => row["amount_minor"],
      "currency" => row["currency"] || "GHS",
      "status" => row["status"]
    }
  end

  defp receipt_value(receipt, key) when is_map(receipt) do
    Map.get(receipt, key) || Map.get(receipt, Atom.to_string(key))
  end

  defp paystack_checkout_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "checkout.paystack.com", path: "/" <> rest} when rest != "" ->
        true

      _ ->
        false
    end
  end

  defp paystack_checkout_url?(_), do: false

  defp pay_url(token) do
    "#{PaymentTemplate.public_base()}/pay/#{token}"
  end

  defp select_sql do
    "SELECT #{Enum.join(@columns, ", ")} FROM public.direct_payment_requests"
  end

  defp row_map(row) do
    Map.new(Enum.zip(@columns, row))
  end

  defp token_ok?(token), do: String.match?(token, @token)

  defp table?(name) do
    case Repo.query("SELECT to_regclass($1)::text", [name]) do
      {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp random_token, do: random_hex(32)
  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error
  defp dump!(value), do: Ecto.UUID.dump!(value)
  defp dump_optional(nil), do: nil
  defp dump_optional(value), do: Ecto.UUID.dump!(value)

  defp uuid_string(nil), do: nil

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.load!(value)
    end
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: value

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_transaction({:error, error}), do: database_error(error)

  defp unwrap_checkout_error({:ok, {:checkout_error, reason}}), do: {:error, reason}
  defp unwrap_checkout_error(result), do: result

  defp database_error(error) do
    Logger.error("Direct payment request database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
