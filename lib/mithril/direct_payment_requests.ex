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

  @columns ~w(
    id public_token customer_user_id customer_name phone_e164 email description
    amount_minor currency status channel paystack_reference authorization_url
    delivery_error idempotency_key sent_at paid_at created_at
  )
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
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
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
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        end)
        |> normalize_transaction()
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
            if stored == String.trim(reference),
              do: public_json(row),
              else: Repo.rollback(:not_found)

          %{"paystack_reference" => stored} = row ->
            if stored != String.trim(reference) do
              Repo.rollback(:not_found)
            else
              case confirm_paid(row) do
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
        {:ok, %{rows: []}} -> :unknown
        {:ok, %{rows: [row]}} -> apply_webhook(row_map(row), event)
        {:error, error} -> database_error(error)
      end
    else
      :unknown
    end
  end

  def settle_charge(_), do: :unknown

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

  defp insert_and_send(admin_uid, input) do
    id = Ecto.UUID.generate()
    token = random_token()
    reference = "icpr_" <> random_hex(12)

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
      dump!(input.idempotency_key)
    ]

    case Repo.query(
           """
           INSERT INTO public.direct_payment_requests (
             id, public_token, customer_user_id, customer_name, phone_e164, email,
             description, amount_minor, paystack_reference, created_by, idempotency_key
           ) VALUES (
             $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
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
        if mapped["sent_at"], do: {:ok, admin_json(mapped)}, else: send_and_present(row)

      {:ok, %{rows: []}} ->
        {:error, :invalid_request}

      {:error, error} ->
        database_error(error)
    end
  end

  defp send_and_present(row) do
    request = row_map(row)

    case deliver(request) do
      {:ok, channel} ->
        case mark_sent(request["id"], channel) do
          {:ok, updated} ->
            {:ok, admin_json(updated)}

          {:error, _} ->
            {:ok,
             admin_json(
               Map.merge(request, %{"channel" => channel, "sent_at" => DateTime.utc_now()})
             )}
        end

      {:error, reason} ->
        _ = mark_delivery_error(request["id"], reason)
        {:ok, admin_json(Map.put(request, "delivery_error", Atom.to_string(reason)))}
    end
  end

  defp deliver(request) do
    case whatsapp(request) do
      :ok ->
        {:ok, "whatsapp"}

      {:error, :twilio_unavailable} ->
        {:error, :delivery_unknown}

      _other ->
        sms(request)
    end
  end

  defp whatsapp(request) do
    with {:ok, sid} <- PaymentTemplate.ensure(),
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
        })
      )
    end
  end

  defp sms(request) do
    case SMS.send_message(request["phone_e164"], sms_body(request)) do
      :ok -> {:ok, "sms"}
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
    url = row["authorization_url"]

    if paystack_checkout_url?(url) do
      {:ok, checkout_json(row, url)}
    else
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

      case Paystack.initialize(attrs) do
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
          {:error, :payment_unavailable}
      end
    end
  end

  defp confirm_paid(row) do
    case Paystack.verify(row["paystack_reference"]) do
      {:ok, receipt} ->
        cond do
          receipt_value(receipt, :status) != "success" ->
            {:error, :payment_incomplete}

          receipt_value(receipt, :amount) != row["amount_minor"] ->
            {:error, :amount_mismatch}

          receipt_value(receipt, :currency) != (row["currency"] || "GHS") ->
            {:error, :amount_mismatch}

          receipt_value(receipt, :reference) not in [nil, row["paystack_reference"]] ->
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

  defp mark_sent(id, channel) do
    case Repo.query(
           """
           UPDATE public.direct_payment_requests
           SET channel = $2, sent_at = now(), delivery_error = NULL, updated_at = now()
           WHERE id = $1
           RETURNING #{Enum.join(@columns, ", ")}
           """,
           [id, channel]
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
         {:ok, key} <- required_uuid(params["idempotencyKey"] || params[:idempotencyKey]) do
      {:ok,
       %{
         customer_name: name,
         phone: phone,
         description: description,
         amount_minor: amount,
         customer_user_id: customer_id,
         email: email,
         idempotency_key: key
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
      "createdAt" => timestamp(row["created_at"])
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

  defp database_error(error) do
    Logger.error("Direct payment request database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
