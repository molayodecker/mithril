defmodule Mithril.Sumsub.Webhook do
  @moduledoc false

  require Logger

  alias Mithril.Auth.Phone
  alias Mithril.Repo

  @default_worker_level_name "id-and-liveness"

  def handle(raw_body, digest_header) when is_binary(raw_body) do
    request_id = Ecto.UUID.generate()

    with {:ok, secret} <- webhook_secret(),
         :ok <- verify_signature(secret, raw_body, digest_header),
         {:ok, payload} <- decode_payload(raw_body),
         {:ok, event} <- parse_event(payload),
         {:ok, result} <- persist(event) do
      {:ok, Map.put(result, :request_id, request_id)}
    else
      {:error, :not_configured} = error ->
        Logger.error("sumsub webhook missing SUMSUB_WEBHOOK_SECRET request_id=#{request_id}")
        error

      {:error, :unauthorized} = error ->
        Logger.warning("sumsub webhook invalid signature request_id=#{request_id}")
        error

      {:error, :invalid_json} = error ->
        Logger.warning("sumsub webhook invalid JSON request_id=#{request_id}")
        error

      {:error, :invalid_payload} = error ->
        Logger.warning("sumsub webhook missing required fields request_id=#{request_id}")
        error

      {:error, :conflict} = error ->
        Logger.warning("sumsub webhook applicant/user conflict request_id=#{request_id}")
        error

      {:error, error} ->
        Logger.error(
          "sumsub webhook persist failed request_id=#{request_id} error=#{inspect(error)}"
        )

        {:error, :database_unavailable}
    end
  end

  def handle(_raw_body, _digest_header), do: {:error, :invalid_payload}

  def verify_signature(secret, raw_body, digest_header)
      when is_binary(secret) and is_binary(raw_body) and is_binary(digest_header) do
    digest =
      digest_header
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("sha256=", "")

    expected =
      :hmac
      |> :crypto.mac(:sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    if byte_size(digest) == byte_size(expected) and Plug.Crypto.secure_compare(digest, expected) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def verify_signature(_secret, _raw_body, _digest_header), do: {:error, :unauthorized}

  # Event types currently subscribed in the Sumsub dashboard.
  @final_review_types ~w(applicantreviewed applicantactionreviewed)

  @in_progress_types ~w(
    applicantpending
    applicantonhold
    applicantprechecked
    applicantawaitinguser
    applicantawaitingservice
    applicantactionpending
    applicantactiononhold
  )

  @lifecycle_types ~w(
    applicantcreated
    applicantactivated
    applicantdeactivated
    applicantdeleted
    applicantreset
    applicantpersonalinfochanged
    applicantpersonaldatadeleted
    applicanttagschanged
  )

  def map_kyc_status(event_type, review_answer) do
    normalized_type = normalize_type(event_type)
    answer = review_answer && String.upcase(review_answer)

    cond do
      normalized_type in @final_review_types and answer == "GREEN" ->
        "completed"

      normalized_type in @final_review_types and answer == "RED" ->
        "rejected"

      normalized_type in @final_review_types or normalized_type in @in_progress_types ->
        "submitted"

      normalized_type in @lifecycle_types ->
        "started"

      true ->
        "started"
    end
  end

  def intermediate_event?(event_type, review_answer) do
    normalized_type = normalize_type(event_type)
    answer = review_answer && String.upcase(review_answer)

    cond do
      normalized_type in @final_review_types and answer in ["GREEN", "RED"] ->
        false

      normalized_type == "applicantreset" ->
        false

      true ->
        true
    end
  end

  def preserve_final_review?(existing, event_type, review_answer) do
    final_review?(existing) and intermediate_event?(event_type, review_answer)
  end

  defp persist(event) do
    Repo.transaction(fn ->
      lock_user!(event.external_user_id)
      existing = fetch_kyc_for_update(event.applicant_id)

      cond do
        existing && existing.user_id != event.user_id ->
          Repo.rollback(:conflict)

        unexpected_worker_level?(event, existing) ->
          Logger.warning(
            "sumsub webhook ignored worker event for unexpected level applicant=#{event.applicant_id} level=#{inspect(event.level_name)}"
          )

          ignored_level_result(event)

        true ->
          event = %{event | level_name: expected_worker_level_name()}
          latest = fetch_latest_kyc_for_user_level(event.user_id)
          apply_event(existing, latest, event, false)
      end
    end)
    |> normalize_transaction()
  end

  defp apply_event(existing, latest, event, retried?) do
    cond do
      existing && existing.user_id != event.user_id ->
        Repo.rollback(:conflict)

      stale_event?(existing, latest, event) ->
        source = latest || existing

        Logger.info(
          "sumsub webhook skipped stale/duplicate event applicant=#{event.applicant_id} incoming_ms=#{inspect(event.created_at_ms)} stored_ms=#{inspect(source && source.last_event_created_at_ms)}"
        )

        success_result(
          source || %{kyc_status: map_kyc_status(event.type, event.review_answer)},
          event,
          source && source.worker_application_id,
          true
        )

      true ->
        persist_locked(existing, event, retried?)
    end
  end

  defp persist_locked(existing, event, retried?) do
    worker_application_id = resolve_worker_application_id(existing, event.user_id)

    preserve = preserve_final_review?(existing, event.type, event.review_answer)
    kyc_status = effective_kyc_status(existing, event, preserve)
    review_answer = if preserve, do: existing.review_answer, else: event.review_answer
    review_reason = if preserve, do: existing.review_reason, else: event.review_reason
    now = DateTime.utc_now()

    {submitted_at, reviewed_at, completed_at} =
      lifecycle_timestamps(existing, event, kyc_status, preserve, now)

    ctx = %{
      existing: existing,
      event: event,
      worker_application_id: worker_application_id,
      kyc_status: kyc_status,
      review_answer: review_answer,
      review_reason: review_reason,
      submitted_at: submitted_at,
      reviewed_at: reviewed_at,
      completed_at: completed_at
    }

    case write_kyc_profile(ctx) do
      :ok ->
        mirrored_id =
          if worker_application_id do
            mirror_worker_tables(
              event,
              worker_application_id,
              kyc_status,
              review_answer,
              preserve,
              now
            )
          else
            sync_orphaned_worker_verification(event.user_id, kyc_status, now)
            nil
          end

        success_result(%{kyc_status: kyc_status}, event, mirrored_id, false)

      :insert_race when retried? == false ->
        existing = fetch_kyc_for_update(event.applicant_id)
        latest = fetch_latest_kyc_for_user_level(event.user_id)
        apply_event(existing, latest, event, true)

      :insert_race ->
        Repo.rollback(:conflict)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp success_result(source, event, worker_application_id, skipped_stale) do
    kyc_status = source.kyc_status || source[:kyc_status]

    %{
      applicant_id: event.applicant_id,
      external_user_id: event.external_user_id,
      kyc_status: kyc_status,
      worker_mirrored: not is_nil(worker_application_id) and skipped_stale == false,
      worker_application_id: worker_application_id,
      worker_application_kyc_status:
        if(worker_application_id, do: map_worker_application_status(kyc_status)),
      worker_verification_status:
        if(worker_application_id, do: map_worker_verification_status(kyc_status)),
      skipped_stale: skipped_stale
    }
  end

  defp stale_event?(existing, latest, event) do
    duplicate_event?(existing, event) or stale_for_same_applicant?(existing, event) or
      stale_across_applicants?(latest, event)
  end

  defp duplicate_event?(
         %{
           last_event_created_at_ms: stored_ms,
           last_event_type: stored_type,
           review_answer: stored_answer,
           review_reason: stored_reason
         },
         %{
           created_at_ms: incoming_ms,
           type: incoming_type,
           review_answer: incoming_answer,
           review_reason: incoming_reason
         }
       )
       when is_integer(stored_ms) and is_integer(incoming_ms) do
    stored_ms == incoming_ms and normalize_type(stored_type) == normalize_type(incoming_type) and
      normalize_optional(stored_answer) == normalize_optional(incoming_answer) and
      normalize_optional(stored_reason) == normalize_optional(incoming_reason)
  end

  defp duplicate_event?(_existing, _event), do: false

  defp stale_for_same_applicant?(nil, _event), do: false

  defp stale_for_same_applicant?(
         %{last_event_created_at_ms: stored},
         %{created_at_ms: incoming}
       )
       when is_integer(stored) and is_integer(incoming) do
    incoming < stored
  end

  defp stale_for_same_applicant?(_existing, _event), do: false

  defp stale_across_applicants?(
         %{applicant_id: applicant_id, last_event_created_at_ms: stored},
         %{applicant_id: incoming_applicant_id, created_at_ms: incoming}
       )
       when applicant_id != incoming_applicant_id and is_integer(stored) and is_integer(incoming) do
    incoming <= stored
  end

  defp stale_across_applicants?(
         %{applicant_id: applicant_id, last_event_created_at_ms: stored},
         %{applicant_id: incoming_applicant_id, created_at_ms: nil}
       )
       when applicant_id != incoming_applicant_id and is_integer(stored) do
    true
  end

  defp stale_across_applicants?(_latest, _event), do: false

  defp lock_user!(external_user_id) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [external_user_id]) do
      {:ok, _} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp write_kyc_profile(ctx) do
    payload_json = Jason.encode!(ctx.event.payload)
    document_types = ctx.event.document_types
    params = [
      ctx.event.user_id,
      ctx.event.applicant_id,
      ctx.event.external_user_id,
      ctx.worker_application_id,
      ctx.kyc_status,
      ctx.review_answer,
      ctx.review_reason,
      ctx.event.level_name,
      ctx.event.country_code,
      document_types,
      ctx.event.type,
      ctx.event.created_at_ms,
      payload_json,
      ctx.submitted_at,
      ctx.reviewed_at,
      ctx.completed_at
    ]

    if ctx.existing do
      update_kyc_profile(params, ctx.existing.id)
    else
      insert_kyc_profile(params)
    end
  end

  defp insert_kyc_profile(params) do
    case Repo.query(
           """
           INSERT INTO public.kyc_profiles (
             user_id, sumsub_applicant_id, sumsub_external_user_id,
             cleaner_application_id, kyc_status, review_answer, review_reason,
             level_name, country_code, document_types, last_event_type,
             last_event_created_at_ms, last_webhook_payload, submitted_at,
             reviewed_at, completed_at, updated_at
           ) VALUES (
             $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb,
             $14, $15, $16, now()
           )
           ON CONFLICT (sumsub_applicant_id) DO NOTHING
           RETURNING id
           """,
           params
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> :insert_race
      {:error, error} -> {:error, error}
    end
  end

  defp update_kyc_profile(params, id) do
    case Repo.query(
           """
           UPDATE public.kyc_profiles SET
             user_id = $1,
             sumsub_applicant_id = $2,
             sumsub_external_user_id = $3,
             cleaner_application_id = $4,
             kyc_status = $5,
             review_answer = $6,
             review_reason = $7,
             level_name = $8,
             country_code = $9,
             document_types = $10,
             last_event_type = $11,
             last_event_created_at_ms = $12,
             last_webhook_payload = $13::jsonb,
             submitted_at = $14,
             reviewed_at = $15,
             completed_at = $16,
             updated_at = now()
           WHERE id = $17
           """,
           params ++ [id]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mirror_worker_tables(
         event,
         worker_application_id,
         kyc_status,
         review_answer,
         preserve,
         now
       ) do
    app_status = map_worker_application_status(kyc_status)
    verification_status = map_worker_verification_status(kyc_status)
    review_status = if preserve, do: "completed", else: event.review_status
    completed_at = if kyc_status == "completed", do: now, else: nil

    app_result =
      Repo.query(
        """
        UPDATE public.cleaner_applications SET
          kyc_provider = 'sumsub',
          sumsub_applicant_id = $3,
          sumsub_level_name = $4,
          kyc_status = $5,
          kyc_review_answer = $6,
          kyc_review_status = $7,
          kyc_provider_event = $8,
          kyc_last_event_at = $9,
          kyc_completed_at = CASE WHEN $11 THEN kyc_completed_at ELSE $10 END,
          updated_at = $9
        WHERE id = $1
          AND user_id = $2
        RETURNING id
        """,
        [
          worker_application_id,
          event.user_id,
          event.applicant_id,
          event.level_name,
          app_status,
          review_answer,
          review_status,
          event.type,
          now,
          completed_at,
          preserve
        ]
      )

    case app_result do
      {:ok, %{num_rows: 0}} ->
        Logger.warning(
          "sumsub webhook worker application missing or ownership changed applicant=#{event.applicant_id}"
        )

        nil

      {:ok, _} ->
        upsert_worker_verification(event.user_id, verification_status, now)
        worker_application_id

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp sync_orphaned_worker_verification(_user_id, kyc_status, _now)
       when kyc_status in ["completed", "approved"],
       do: :ok

  defp sync_orphaned_worker_verification(user_id, kyc_status, now) do
    upsert_worker_verification(user_id, map_worker_verification_status(kyc_status), now)
  end

  defp upsert_worker_verification(user_id, status, now) do
    case Repo.query(
           """
           INSERT INTO public.cleaner_verifications (id, user_id, status, updated_at)
           VALUES ($1, $1, $2, $3)
           ON CONFLICT (id) DO UPDATE SET
             user_id = EXCLUDED.user_id,
             status = EXCLUDED.status,
             updated_at = EXCLUDED.updated_at
           """,
           [user_id, status, now]
         ) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp fetch_kyc_for_update(applicant_id) do
    case Repo.query(
           """
           SELECT id, user_id, level_name, cleaner_application_id, submitted_at,
                  reviewed_at, completed_at, kyc_status, review_answer, review_reason,
                  last_event_created_at_ms, sumsub_applicant_id, last_event_type, last_webhook_payload
           FROM public.kyc_profiles
           WHERE sumsub_applicant_id = $1
           FOR UPDATE
           """,
           [applicant_id]
         ) do
      {:ok, %{rows: [row]}} ->
        kyc_row(row)

      {:ok, %{rows: []}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp fetch_latest_kyc_for_user_level(user_id) do
    case Repo.query(
           """
           SELECT id, user_id, level_name, cleaner_application_id, submitted_at,
                  reviewed_at, completed_at, kyc_status, review_answer, review_reason,
                  last_event_created_at_ms, sumsub_applicant_id, last_event_type, last_webhook_payload
           FROM public.kyc_profiles
           WHERE user_id = $1
             AND lower(trim(COALESCE(level_name, ''))) = $2
           ORDER BY last_event_created_at_ms DESC NULLS LAST, updated_at DESC, created_at DESC
           LIMIT 1
           FOR UPDATE
           """,
           [user_id, expected_worker_level_name()]
         ) do
      {:ok, %{rows: [row]}} -> kyc_row(row)
      {:ok, %{rows: []}} -> nil
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp kyc_row([
         id,
         user_id,
         level_name,
         worker_application_id,
         submitted_at,
         reviewed_at,
         completed_at,
         kyc_status,
         review_answer,
         review_reason,
         last_event_created_at_ms,
         applicant_id,
         last_event_type,
         last_webhook_payload
       ]) do
    %{
      id: id,
      user_id: user_id,
      level_name: level_name,
      worker_application_id: worker_application_id,
      submitted_at: submitted_at,
      reviewed_at: reviewed_at,
      completed_at: completed_at,
      kyc_status: kyc_status,
      review_answer: review_answer,
      review_reason: review_reason,
      last_event_created_at_ms: last_event_created_at_ms,
      applicant_id: applicant_id,
      last_event_type: last_event_type,
      last_webhook_payload: last_webhook_payload
    }
  end

  defp resolve_worker_application_id(existing, user_id) do
    case existing && existing.worker_application_id do
      nil ->
        find_worker_application_id(user_id)

      application_id ->
        case lock_worker_application(application_id) do
          nil ->
            find_worker_application_id(user_id)

          %{user_id: ^user_id} ->
            application_id

          %{user_id: nil} ->
            claim_worker_application(application_id, user_id)

          _owned_by_another_user ->
            find_worker_application_id(user_id)
        end
    end
  end

  defp lock_worker_application(application_id) do
    case Repo.query(
           """
           SELECT user_id
           FROM public.cleaner_applications
           WHERE id = $1
           FOR UPDATE
           """,
           [application_id]
         ) do
      {:ok, %{rows: [[user_id]]}} -> %{user_id: user_id}
      {:ok, %{rows: []}} -> nil
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> nil
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp find_worker_application_id(user_id) do
    case Repo.query(
           """
           SELECT id
           FROM public.cleaner_applications
           WHERE user_id = $1
           ORDER BY created_at DESC NULLS LAST
           LIMIT 1
           FOR UPDATE
           """,
           [user_id]
         ) do
      {:ok, %{rows: [[id]]}} ->
        id

      {:ok, %{rows: []}} ->
        find_worker_application_by_contact(user_id)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp find_worker_application_by_contact(user_id) do
    case Repo.query("SELECT phone, email FROM public.users WHERE id = $1 LIMIT 1", [user_id]) do
      {:ok, %{rows: [[phone, email]]}} ->
        find_worker_application_by_phone(phone, user_id) ||
          find_worker_application_by_email(email, user_id)

      {:ok, %{rows: []}} ->
        nil

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp find_worker_application_by_phone(phone, user_id) when is_binary(phone) and phone != "" do
    variants = phone_variants(phone)

    if variants == [] do
      nil
    else
      case Repo.query(
             """
             SELECT id
             FROM public.cleaner_applications
             WHERE user_id IS NULL
               AND phone = ANY($1::text[])
             ORDER BY created_at DESC NULLS LAST
             LIMIT 1
             FOR UPDATE
             """,
             [variants]
           ) do
        {:ok, %{rows: [[id]]}} -> claim_worker_application(id, user_id)
        {:ok, %{rows: []}} -> nil
        {:error, error} -> Repo.rollback(error)
      end
    end
  end

  defp find_worker_application_by_phone(_, _user_id), do: nil

  defp find_worker_application_by_email(email, user_id) when is_binary(email) do
    email = String.trim(email) |> String.downcase()

    if email == "" do
      nil
    else
      case Repo.query(
             """
             SELECT id
             FROM public.cleaner_applications
             WHERE user_id IS NULL
               AND lower(email) = $1
             ORDER BY created_at DESC NULLS LAST
             LIMIT 1
             FOR UPDATE
             """,
             [email]
           ) do
        {:ok, %{rows: [[id]]}} -> claim_worker_application(id, user_id)
        {:ok, %{rows: []}} -> nil
        {:error, error} -> Repo.rollback(error)
      end
    end
  end

  defp find_worker_application_by_email(_, _user_id), do: nil

  defp claim_worker_application(application_id, user_id) do
    case Repo.query(
           """
           UPDATE public.cleaner_applications
           SET user_id = $2, updated_at = now()
           WHERE id = $1
             AND user_id IS NULL
           RETURNING id
           """,
           [application_id, user_id]
         ) do
      {:ok, %{rows: [[id]]}} -> id
      {:ok, %{rows: []}} -> nil
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp parse_event(payload) when is_map(payload) do
    type = string_field(payload, "type")
    applicant_id = string_field(payload, "applicantId")
    external_user_id = string_field(payload, "externalUserId")
    review_result = map_field(payload, "reviewResult")

    with true <- type != "" and applicant_id != "" and external_user_id != "",
         {:ok, user_id} <- dump_uuid(external_user_id),
         {:ok, created_at_ms} <- event_created_at_ms(payload, "createdAtMs") do
      review_answer = string_field(review_result, "reviewAnswer")
      review_answer = if review_answer == "", do: nil, else: review_answer
      review_reason = string_field(review_result, "reviewRejectType")
      review_reason = if review_reason == "", do: nil, else: review_reason
      level_name = nullable_string(payload, "levelName")

      country_code =
        nullable_string(payload, "country") || nullable_string(payload, "countryCode")

      review_status = string_field(payload, "reviewStatus")
      review_status = if review_status == "", do: type, else: review_status

      {:ok,
       %{
         type: type,
         applicant_id: applicant_id,
         external_user_id: external_user_id,
         user_id: user_id,
         level_name: level_name,
         country_code: country_code,
         document_types: document_types(payload["documentTypes"]),
         created_at_ms: created_at_ms,
         review_status: review_status,
         review_answer: review_answer,
         review_reason: review_reason,
         payload: payload
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp unexpected_worker_level?(event, existing) do
    expected = expected_worker_level_name()
    event_level = normalize_level_name(event.level_name)

    cond do
      event_level != "" ->
        event_level != expected

      existing ->
        normalize_level_name(existing.level_name) != expected

      true ->
        true
    end
  end

  defp expected_worker_level_name do
    :mithril
    |> Application.get_env(:sumsub_worker_level_name, @default_worker_level_name)
    |> normalize_level_name()
  end

  defp normalize_level_name(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_level_name(_), do: ""

  defp ignored_level_result(event) do
    %{
      applicant_id: event.applicant_id,
      external_user_id: event.external_user_id,
      kyc_status: nil,
      worker_mirrored: false,
      worker_application_id: nil,
      worker_application_kyc_status: nil,
      worker_verification_status: nil,
      skipped_stale: true,
      ignored_level: true
    }
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp webhook_secret do
    case Application.get_env(:mithril, :sumsub_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  defp final_review?(nil), do: false

  defp final_review?(existing) do
    answer = existing.review_answer && String.upcase(existing.review_answer)
    status = existing.kyc_status && String.downcase(existing.kyc_status)

    answer in ["GREEN", "RED"] or status in ["completed", "rejected", "approved"]
  end

  defp effective_kyc_status(existing, event, true) do
    answer = existing.review_answer && String.upcase(existing.review_answer)

    cond do
      answer == "GREEN" -> "completed"
      answer == "RED" -> "rejected"
      true -> existing.kyc_status || map_kyc_status(event.type, event.review_answer)
    end
  end

  defp effective_kyc_status(_existing, event, false) do
    map_kyc_status(event.type, event.review_answer)
  end

  defp lifecycle_timestamps(existing, _event, _status, true, _now) do
    {
      existing && existing.submitted_at,
      existing && existing.reviewed_at,
      existing && existing.completed_at
    }
  end

  defp lifecycle_timestamps(existing, event, status, false, now) do
    submitted_at =
      if status in ["submitted", "completed", "rejected"] do
        (existing && existing.submitted_at) || now
      end

    reviewed_at =
      if normalize_type(event.type) in @final_review_types do
        now
      end

    completed_at =
      if status == "completed" do
        if existing && existing.kyc_status in ["completed", "approved"] &&
             existing.review_answer && String.upcase(existing.review_answer) == "GREEN" do
          existing.completed_at || now
        else
          now
        end
      end

    {submitted_at, reviewed_at, completed_at}
  end

  defp map_worker_application_status(status) when status in ["completed", "approved"],
    do: "completed"

  defp map_worker_application_status("rejected"), do: "rejected"
  defp map_worker_application_status("submitted"), do: "pending"
  defp map_worker_application_status(_), do: "not_started"

  defp map_worker_verification_status(status) when status in ["completed", "approved"],
    do: "verified"

  defp map_worker_verification_status("rejected"), do: "rejected"
  defp map_worker_verification_status("submitted"), do: "pending"
  defp map_worker_verification_status(_), do: "unverified"

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "")
  end

  defp normalize_type(_), do: ""

  defp normalize_optional(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_optional(_), do: nil

  defp string_field(nil, _key), do: ""

  defp string_field(map, key) when is_map(map) do
    case map[key] do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp nullable_string(map, key) do
    case string_field(map, key) do
      "" -> nil
      value -> value
    end
  end

  defp map_field(map, key) when is_map(map) do
    case map[key] do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp event_created_at_ms(map, key) when is_map(map) do
    case map[key] do
      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        parse_sumsub_timestamp(value)

      _ ->
        :error
    end
  end

  defp parse_sumsub_timestamp(value) do
    iso8601 =
      value
      |> String.trim()
      |> String.replace(" ", "T", global: false)

    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_unix(datetime, :millisecond)}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(iso8601) do
          {:ok, naive_datetime} ->
            datetime = DateTime.from_naive!(naive_datetime, "Etc/UTC")
            {:ok, DateTime.to_unix(datetime, :millisecond)}

          {:error, _reason} ->
            :error
        end
    end
  end

  defp document_types(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      types -> types
    end
  end

  defp document_types(_), do: nil

  defp phone_variants(phone) do
    trimmed = String.trim(phone)

    case Phone.normalize(trimmed) do
      {:ok, e164} ->
        digits = String.replace(e164, ~r/\D/, "")

        local =
          if String.starts_with?(digits, "233"),
            do: "0" <> String.slice(digits, 3..-1//1),
            else: nil

        [e164, "+" <> digits, digits, local, trimmed]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))
        |> Enum.uniq()

      :error ->
        if trimmed == "", do: [], else: [trimmed]
    end
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}

  defp normalize_transaction({:error, reason}) do
    Logger.error("sumsub webhook database error: #{inspect(reason)}")
    {:error, :database_unavailable}
  end
end
