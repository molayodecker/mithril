defmodule Mithril.DirectAdminPayoutNameReviews do
  @moduledoc """
  Holds a payout account while staff compare the profile name with the name
  on the mobile-money or bank account.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.Notifications.Templates
  alias Mithril.PayoutNameMatch
  alias Mithril.Repo
  alias Mithril.SupportOps

  @pending "pending"
  @statuses ~w(pending approved rejected)

  def open(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    notify = Map.get(attrs, :notify, &SupportOps.notify/1)

    with {:ok, user_uid} <- dump_uuid(user_id) do
      profile_name = profile_display_name(user_uid)
      account_name = present(attrs[:account_name] || attrs["account_name"])
      submitted_name = present(attrs[:submitted_name] || attrs["submitted_name"])
      wallet_name = account_name || submitted_name
      names_match = PayoutNameMatch.names_match?(profile_name, wallet_name)
      purpose = purpose(attrs[:purpose] || attrs["purpose"])
      payout_type = payout_type(attrs[:payout_type] || attrs["payout_type"])
      account_number = present(attrs[:account_number] || attrs["account_number"]) || ""
      bank_code = present(attrs[:bank_code] || attrs["bank_code"])

      case upsert_pending(user_uid, %{
             purpose: purpose,
             payout_type: payout_type,
             profile_name: profile_name,
             account_name: wallet_name,
             submitted_name: submitted_name,
             names_match: names_match,
             bank_code: bank_code,
             account_number: account_number
           }) do
        {:ok, %{id: review_id, inserted: inserted}} ->
          sync_mismatch_flag(user_uid, purpose)

          notified =
            inserted and not names_match and
              notify_admin(notify, user_id, profile_name, wallet_name, payout_type)

          {:ok,
           %{
             id: review_id,
             names_match: names_match,
             account_name: wallet_name,
             notified: notified
           }}

        {:error, reason} ->
          Logger.warning("payout name review was not saved: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_user}
    end
  end

  def list(user_id, params \\ %{}) do
    with {:ok, _admin_uid} <- dump_uuid(user_id),
         :ok <- require_staff(user_id),
         {:ok, status} <- status_filter(params) do
      list_rows(status)
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def show(user_id, review_id) do
    with {:ok, _admin_uid} <- dump_uuid(user_id),
         :ok <- require_staff(user_id),
         {:ok, review_uid} <- dump_uuid(review_id) do
      case fetch_rows(review_uid, nil) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:error, :review_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def review(user_id, review_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_staff(user_id),
         {:ok, review_uid} <- dump_uuid(review_id),
         {:ok, decision} <- decision(params["decision"] || params[:decision]),
         {:ok, notes} <- optional_notes(params["reviewNotes"] || params[:reviewNotes]) do
      decide(admin_uid, review_uid, decision, notes)
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def hold_body(names_match, account_name) do
    %{
      ok: true,
      code: "PAYOUT_NAME_REVIEW",
      data: %{
        held: true,
        names_match: names_match == true,
        account_name: account_name
      }
    }
  end

  defp upsert_pending(user_uid, fields) do
    case Repo.query(
           """
           INSERT INTO public.payout_name_reviews (
             user_id, purpose, payout_type, profile_name, account_name, submitted_name,
             names_match, status, bank_code, account_number
           )
           VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', $8, $9)
           ON CONFLICT (user_id, purpose, account_number) WHERE status = 'pending'
           DO UPDATE SET
             payout_type = EXCLUDED.payout_type,
             profile_name = EXCLUDED.profile_name,
             account_name = EXCLUDED.account_name,
             submitted_name = EXCLUDED.submitted_name,
             names_match = EXCLUDED.names_match,
             bank_code = EXCLUDED.bank_code,
             updated_at = now()
           RETURNING id, (xmax = 0) AS inserted
           """,
           [
             user_uid,
             fields.purpose,
             fields.payout_type,
             fields.profile_name,
             fields.account_name,
             fields.submitted_name,
             fields.names_match,
             fields.bank_code,
             fields.account_number
           ]
         ) do
      {:ok, %{rows: [[id, inserted]]}} ->
        {:ok, %{id: uuid_string(id), inserted: inserted == true}}

      {:error, error} ->
        {:error, database_reason(error)}
    end
  end

  defp list_rows(status) do
    {where, args} =
      if status do
        {"WHERE r.status = $1", [status]}
      else
        {"", []}
      end

    fetch_rows(nil, {where, args})
  end

  defp fetch_rows(review_uid, filter) do
    {where, args} =
      cond do
        review_uid ->
          {"WHERE r.id = $1::uuid", [review_uid]}

        filter ->
          filter

        true ->
          {"", []}
      end

    case Repo.query(
           """
           SELECT
             r.id,
             r.user_id,
             COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               r.profile_name,
               'Cleaner'
             ),
             r.profile_name,
             r.account_name,
             r.submitted_name,
             r.names_match,
             r.status,
             r.purpose,
             r.payout_type,
             CASE
               WHEN length(regexp_replace(coalesce(r.account_number, ''), '\\D', '', 'g')) >= 4
               THEN '•••• ' || right(regexp_replace(r.account_number, '\\D', '', 'g'), 4)
               ELSE NULL
             END,
             r.review_notes,
             r.created_at,
             r.reviewed_at
           FROM public.payout_name_reviews r
           LEFT JOIN public.profiles p ON p.id = r.user_id
           #{where}
           ORDER BY r.created_at DESC
           LIMIT 100
           """,
           args
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &present_row/1)}
      {:error, error} -> {:error, database_reason(error)}
    end
  end

  defp decide(admin_uid, review_uid, decision, notes) do
    status = if decision == "approve", do: "approved", else: "rejected"

    case Repo.query(
           """
           UPDATE public.payout_name_reviews
           SET status = $2,
               review_notes = $3,
               reviewed_by = $4,
               reviewed_at = now(),
               updated_at = now()
           WHERE id = $1
             AND status = 'pending'
           RETURNING id, user_id, purpose, names_match, status
           """,
           [review_uid, status, notes, admin_uid]
         ) do
      {:ok, %{rows: [[id, user_uid, purpose, names_match, status]]}} ->
        sync_mismatch_flag(user_uid, purpose)

        {:ok,
         %{
           "id" => uuid_string(id),
           "status" => status,
           "namesMatch" => names_match,
           "recipientCreated" => false
         }}

      {:ok, %{rows: []}} ->
        review_missing_or_closed(review_uid)

      {:error, error} ->
        {:error, database_reason(error)}
    end
  end

  defp review_missing_or_closed(review_uid) do
    case Repo.query("SELECT status FROM public.payout_name_reviews WHERE id = $1", [review_uid]) do
      {:ok, %{rows: [[_status]]}} -> {:error, :review_not_pending}
      {:ok, %{rows: []}} -> {:error, :review_not_found}
      {:error, error} -> {:error, database_reason(error)}
    end
  end

  # Rebuild the purpose flag from the remaining unresolved review rows. The
  # UPDATE modifies the current JSONB value in PostgreSQL, avoiding lost flags
  # when payout and refund requests are handled concurrently.
  defp sync_mismatch_flag(user_uid, purpose) do
    case Repo.query(
           """
           WITH active AS (
             SELECT jsonb_build_object(
               'flagged_at', to_char(r.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
               'profile_name', coalesce(r.profile_name, ''),
               'payout_account_name', coalesce(r.account_name, ''),
               'payout_type', r.payout_type,
               'purpose', r.purpose
             ) AS flag
             FROM public.payout_name_reviews r
             WHERE r.user_id = $1
               AND r.purpose = $2
               AND r.names_match = false
               AND r.status IN ('pending', 'rejected')
             ORDER BY CASE WHEN r.status = 'pending' THEN 0 ELSE 1 END,
                      r.updated_at DESC, r.id DESC
             LIMIT 1
           ),
           chosen AS (SELECT (SELECT flag FROM active) AS flag)
           UPDATE public.profiles p
           SET preferences =
             CASE
               WHEN chosen.flag IS NULL THEN
                 CASE WHEN $2 = 'payout' THEN
                   (coalesce(p.preferences, '{}'::jsonb) #- ARRAY['payout_name_mismatches', $2]) - 'payout_name_mismatch'
                 ELSE
                   coalesce(p.preferences, '{}'::jsonb) #- ARRAY['payout_name_mismatches', $2]
                 END
               WHEN $2 = 'payout' THEN
                 jsonb_set(
                   jsonb_set(coalesce(p.preferences, '{}'::jsonb),
                             ARRAY['payout_name_mismatches', $2], chosen.flag, true),
                   '{payout_name_mismatch}', chosen.flag, true
                 )
               ELSE
                 jsonb_set(coalesce(p.preferences, '{}'::jsonb),
                           ARRAY['payout_name_mismatches', $2], chosen.flag, true)
             END,
             updated_at = now()
           FROM chosen
           WHERE p.id = $1
           """,
           [user_uid, purpose]
         ) do
      {:ok, _} -> :ok
      {:error, error} ->
        Logger.warning("payout name flag sync failed: #{inspect(error)}")
        {:error, database_reason(error)}
    end
  end

  defp notify_admin(notify, user_id, profile_name, account_name, payout_type) do
    text =
      Templates.body("payout_name_mismatch_report", %{
        "userId" => user_id,
        "profileName" => profile_name || "unknown",
        "payoutAccountName" => account_name || "unknown",
        "payoutType" => payout_type
      })

    result =
      notify.(%{
        subject: Templates.subject("payout_name_mismatch_report"),
        plain_body: text <> " Approve or reject this review in Direct."
      })

    SupportOps.delivered?(result)
  rescue
    error ->
      Logger.warning("payout name review notice failed: #{inspect(error)}")
      false
  end

  defp profile_display_name(user_uid) do
    case Repo.query(
           """
           SELECT COALESCE(
             NULLIF(btrim(fullname), ''),
             NULLIF(btrim(concat_ws(' ', firstname, lastname)), '')
           )
           FROM public.profiles
           WHERE id = $1
           LIMIT 1
           """,
           [user_uid]
         ) do
      {:ok, %{rows: [[name]]}} -> present(name)
      _ -> nil
    end
  end

  defp present_row([
         id,
         user_id,
         cleaner_name,
         profile_name,
         account_name,
         submitted_name,
         names_match,
         status,
         purpose,
         payout_type,
         masked_account,
         review_notes,
         created_at,
         reviewed_at
       ]) do
    %{
      "id" => uuid_string(id),
      "userId" => uuid_string(user_id),
      "cleanerName" => cleaner_name,
      "profileName" => profile_name,
      "accountName" => account_name,
      "submittedName" => submitted_name,
      "namesMatch" => names_match,
      "status" => status,
      "purpose" => purpose,
      "payoutType" => payout_type,
      "maskedAccount" => masked_account,
      "reviewNotes" => review_notes,
      "createdAt" => datetime_to_iso8601(created_at),
      "reviewedAt" => datetime_to_iso8601(reviewed_at)
    }
  end

  defp status_filter(params) do
    raw = params["status"] || params[:status]

    case raw do
      nil -> {:ok, @pending}
      "" -> {:ok, @pending}
      "all" -> {:ok, nil}
      status when status in @statuses -> {:ok, status}
      _ -> {:error, :invalid_request}
    end
  end

  defp decision("approve"), do: {:ok, "approve"}
  defp decision("reject"), do: {:ok, "reject"}
  defp decision(:approve), do: {:ok, "approve"}
  defp decision(:reject), do: {:ok, "reject"}
  defp decision(_), do: {:error, :invalid_decision}

  defp optional_notes(nil), do: {:ok, nil}
  defp optional_notes(""), do: {:ok, nil}

  defp optional_notes(notes) when is_binary(notes) do
    trimmed = String.trim(notes)
    if String.length(trimmed) > 500, do: {:error, :invalid_request}, else: {:ok, trimmed}
  end

  defp optional_notes(_), do: {:error, :invalid_request}

  defp purpose("refund"), do: "refund"
  defp purpose(_), do: "payout"

  defp payout_type("mobile_money"), do: "mobile_money"
  defp payout_type(_), do: "bank"

  defp require_staff(user_id) do
    if Auth.staff_uuid?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> :error
    end
  end

  defp dump_uuid(_), do: :error

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_), do: nil

  defp uuid_string(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp datetime_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_to_iso8601(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp datetime_to_iso8601(_), do: nil

  defp database_reason(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: :missing_table
  defp database_reason(%Postgrex.Error{postgres: %{code: :undefined_column}}), do: :missing_table

  defp database_reason(error) do
    Logger.error("payout name review database error: #{inspect(error)}")
    :database_unavailable
  end
end
