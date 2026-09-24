defmodule Mithril.MobileFunctions.NotifyPaymentFailureOps do
  @moduledoc false

  alias Mithril.Repo

  @allowed_reasons ~w(
    checkout_init_failed
    checkout_init_exception
    checkout_init_no_url
    checkout_status_check_failed
    verify_failed
  )
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  def call(user_id, body) when is_map(body) do
    booking_id = read_id(body, "booking_id", "bookingId")
    subscription_id = read_id(body, "subscription_id", "subscriptionId")
    reason = body |> Map.get("reason", "") |> to_string() |> String.trim()

    cond do
      booking_id == "" and subscription_id == "" ->
        {:error, {:status, 400, %{error: "booking_id or subscription_id is required"}}}

      reason == "" or reason not in @allowed_reasons ->
        {:error, {:status, 400, %{error: "Unsupported payment failure reason"}}}

      booking_id != "" and not Regex.match?(@uuid_regex, booking_id) ->
        {:error, {:status, 400, %{error: "Invalid booking_id"}}}

      subscription_id != "" and not Regex.match?(@uuid_regex, subscription_id) ->
        {:error, {:status, 400, %{error: "Invalid subscription_id"}}}

      true ->
        with :ok <- verify_booking_owner(booking_id, user_id),
             :ok <- verify_subscription_owner(subscription_id, user_id),
             :ok <- enforce_rate_limit(user_id),
             {:ok, idempotency_key} <-
               insert_alert(user_id, body, booking_id, subscription_id, reason) do
          {:ok,
           %{
             received: true,
             recorded: true,
             notified: false,
             duplicate: false,
             idempotency_key: idempotency_key
           }}
        end
    end
  end

  defp read_id(body, snake, camel) do
    (Map.get(body, snake) || Map.get(body, camel) || "")
    |> to_string()
    |> String.trim()
  end

  defp verify_booking_owner("", _user_id), do: :ok

  defp verify_booking_owner(booking_id, user_id) do
    case Repo.query("SELECT customer_id FROM public.bookings WHERE id = $1::uuid LIMIT 1", [
           booking_id
         ]) do
      {:ok, %{rows: [[customer_id]]}} when customer_id == user_id -> :ok
      {:ok, %{rows: [[_]]}} -> {:error, {:status, 403, %{error: "Forbidden"}}}
      _ -> {:error, {:status, 403, %{error: "Forbidden"}}}
    end
  end

  defp verify_subscription_owner("", _user_id), do: :ok

  defp verify_subscription_owner(subscription_id, user_id) do
    case Repo.query("SELECT customer_id FROM public.subscriptions WHERE id = $1::uuid LIMIT 1", [
           subscription_id
         ]) do
      {:ok, %{rows: [[customer_id]]}} when customer_id == user_id -> :ok
      {:ok, %{rows: [[_]]}} -> {:error, {:status, 403, %{error: "Forbidden"}}}
      _ -> {:error, {:status, 403, %{error: "Forbidden"}}}
    end
  end

  defp enforce_rate_limit(user_id) do
    since = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()

    case Repo.query(
           """
           SELECT count(*)::int
           FROM public.payment_failure_ops_alerts
           WHERE source = 'mobile_checkout_failed'
             AND customer_id = $1::uuid
             AND created_at >= $2::timestamptz
           """,
           [user_id, since]
         ) do
      {:ok, %{rows: [[count]]}} when count >= 10 ->
        {:error, {:status, 429, %{error: "Too many payment failure reports"}}}

      {:error, _} ->
        {:error, {:status, 503, %{error: "Rate limit unavailable"}}}

      _ ->
        :ok
    end
  end

  defp insert_alert(user_id, body, booking_id, subscription_id, reason) do
    idempotency_key =
      :crypto.hash(
        :sha256,
        Enum.join(
          [
            user_id,
            booking_id,
            subscription_id,
            reason,
            Integer.to_string(System.system_time(:millisecond))
          ],
          "|"
        )
      )
      |> Base.encode16(case: :lower)

    platform = body |> Map.get("platform", "") |> to_string() |> String.slice(0, 40)
    action = body |> Map.get("action", "") |> to_string() |> String.slice(0, 100)

    transport_failure =
      Map.get(body, "transport_failure") == true or Map.get(body, "transportFailure") == true

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.query(
           """
           INSERT INTO public.payment_failure_ops_alerts (
             idempotency_key, source, customer_id, booking_id, subscription_id,
             reason, action, platform, transport_failure, slack_status, next_retry_at
           ) VALUES (
             $1, 'mobile_checkout_failed', $2::uuid, NULLIF($3, '')::uuid, NULLIF($4, '')::uuid,
             $5, NULLIF($6, ''), NULLIF($7, ''), CASE WHEN $8 THEN true ELSE NULL END,
             'pending', $9::timestamptz
           )
           ON CONFLICT (idempotency_key) DO NOTHING
           RETURNING idempotency_key
           """,
           [
             idempotency_key,
             user_id,
             booking_id,
             subscription_id,
             reason,
             action,
             platform,
             transport_failure,
             now
           ]
         ) do
      {:ok, %{rows: [[stored_key]]}} -> {:ok, stored_key}
      {:ok, %{num_rows: 0}} -> {:ok, idempotency_key}
      {:error, _} -> {:error, {:status, 500, %{error: "Alert persistence failed"}}}
    end
  end
end

defmodule Mithril.MobileFunctions.RankCleanersWithAi do
  @moduledoc false

  alias Mithril.Transport.Ranking

  def call(user_id, body) when is_map(body) do
    Ranking.for_destination(user_id, body)
  end
end

defmodule Mithril.MobileFunctions.RequestDataExport do
  @moduledoc false

  alias Mithril.Repo

  @secret_columns ~w(password_hash encrypted_password feed_url_encrypted)

  def call(user_id, _body) do
    with {:ok, payload} <- build_export(user_id),
         {:ok, email} <- destination_email(user_id),
         :ok <- send_export_email(email, payload) do
      {:ok, %{queued: true, email: email}}
    end
  end

  defp build_export(user_id) do
    tables = [
      {"users",
       "SELECT id, email, phone, created_at, updated_at FROM public.users WHERE id = $1::uuid"},
      {"profiles",
       "SELECT id, user_id, firstname, lastname, fullname, avatar_url, address FROM public.profiles WHERE id = $1::uuid"},
      {"user_roles", "SELECT user_id, role_id FROM public.user_roles WHERE user_id = $1::uuid"},
      {"bookings",
       "SELECT id, status, payment_status, scheduled_date, scheduled_time, address, created_at FROM public.bookings WHERE customer_id = $1::uuid ORDER BY created_at DESC"},
      {"cleaner_applications",
       "SELECT id, status, created_at, updated_at FROM public.cleaner_applications WHERE user_id = $1::uuid ORDER BY created_at DESC"},
      {"kyc_profiles",
       "SELECT id, kyc_status, created_at, updated_at FROM public.kyc_profiles WHERE user_id = $1::uuid ORDER BY updated_at DESC"}
    ]

    export =
      Enum.reduce(tables, %{"exportedAt" => DateTime.utc_now() |> DateTime.to_iso8601()}, fn {key,
                                                                                              sql},
                                                                                             acc ->
        rows =
          case Repo.query(sql, [user_id]) do
            {:ok, %{columns: columns, rows: rows}} ->
              Enum.map(rows, fn row -> row |> Map.new(Enum.zip(columns, row)) |> redact() end)

            _ ->
              []
          end

        Map.put(acc, key, rows)
      end)

    {:ok, export}
  end

  defp redact(row) when is_map(row) do
    Map.drop(row, @secret_columns)
  end

  defp destination_email(user_id) do
    case Repo.query("SELECT email FROM public.users WHERE id = $1::uuid LIMIT 1", [user_id]) do
      {:ok, %{rows: [[email]]}} when is_binary(email) and email != "" ->
        {:ok, email}

      _ ->
        {:error,
         {:status, 400,
          %{
            error:
              "No email address is available for this account. Add an email first, then try again."
          }}}
    end
  end

  defp send_export_email(email, payload) do
    api_key = Application.get_env(:mithril, :resend_api_key, "") |> to_string() |> String.trim()

    if api_key == "" do
      {:error, {:status, 500, %{error: "Email delivery is not configured"}}}
    else
      attachment = payload |> Jason.encode!() |> Base.encode64()

      body = %{
        from:
          Application.get_env(
            :mithril,
            :resend_from,
            "Instaclean <noreply@update.tryinstaclean.com>"
          ),
        to: [email],
        subject: "Your Instaclean data export is ready",
        html: "<p>Your Instaclean account data export is attached as JSON.</p>",
        attachments: [
          %{
            filename: "instaclean-account-data.json",
            content: attachment
          }
        ]
      }

      case Req.post("https://api.resend.com/emails", json: body, auth: {:bearer, api_key}) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, {:status, 502, %{error: "Failed to send export email"}}}
      end
    end
  end
end
