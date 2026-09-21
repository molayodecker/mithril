defmodule Mithril.Sumsub.WebhookTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.Sumsub.Webhook

  setup do
    :ok = Sandbox.checkout(Repo)
    recreate_tables()
    :ok
  end

  test "maps applicantReviewed GREEN to completed" do
    assert Webhook.map_kyc_status("applicantReviewed", "GREEN") == "completed"
    assert Webhook.map_kyc_status("applicantReviewed", "RED") == "rejected"
    assert Webhook.map_kyc_status("applicantPending", nil) == "submitted"
    assert Webhook.map_kyc_status("applicantCreated", nil) == "started"
    assert Webhook.map_kyc_status("applicantAwaitingUser", nil) == "submitted"
    assert Webhook.map_kyc_status("applicantAwaitingService", nil) == "submitted"
    assert Webhook.map_kyc_status("applicantActionPending", nil) == "submitted"
    assert Webhook.map_kyc_status("applicantActionReviewed", "GREEN") == "completed"
    assert Webhook.map_kyc_status("applicantReset", nil) == "started"
  end

  test "does not let onHold wipe a stored GREEN review" do
    existing = %{kyc_status: "completed", review_answer: "GREEN"}

    assert Webhook.preserve_final_review?(existing, "applicantOnHold", nil)
    refute Webhook.preserve_final_review?(existing, "applicantReviewed", "RED")
    assert Webhook.preserve_final_review?(existing, "applicantAwaitingUser", nil)
    assert Webhook.preserve_final_review?(existing, "applicantActionOnHold", nil)
    refute Webhook.preserve_final_review?(existing, "applicantActionReviewed", "RED")
    refute Webhook.preserve_final_review?(existing, "applicantReset", nil)
    refute Webhook.preserve_final_review?(nil, "applicantOnHold", nil)
  end

  test "upserts kyc_profiles and mirrors a worker application" do
    user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")
    insert_application!(application_id, user_id, "cleaner@tryinstaclean.com", "+233555000111")

    payload = reviewed_payload(user_id, "appl-1", "GREEN")
    raw = Jason.encode!(payload)
    digest = sign(raw)

    assert {:ok, result} = Webhook.handle(raw, digest)
    assert result.kyc_status == "completed"
    assert result.worker_mirrored
    assert result.worker_application_id == Ecto.UUID.dump!(application_id)

    [[kyc_status, review_answer]] =
      Repo.query!(
        "SELECT kyc_status, review_answer FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-1"]
      ).rows

    assert kyc_status == "completed"
    assert review_answer == "GREEN"

    [[app_status, provider]] =
      Repo.query!(
        "SELECT kyc_status, kyc_provider FROM public.cleaner_applications WHERE id = $1",
        [Ecto.UUID.dump!(application_id)]
      ).rows

    assert app_status == "completed"
    assert provider == "sumsub"

    [[verification_status]] =
      Repo.query!(
        "SELECT status FROM public.cleaner_verifications WHERE id = $1",
        [Ecto.UUID.dump!(user_id)]
      ).rows

    assert verification_status == "verified"
  end

  test "ignores a final review from a non-worker Sumsub level" do
    user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    insert_user!(user_id, "wrong-level@example.com", "+233555000111")
    insert_application!(application_id, user_id, "wrong-level@example.com", "+233555000111")

    raw =
      reviewed_payload(user_id, "appl-wrong-level", "GREEN", 100)
      |> Map.put("levelName", "basic-kyc")
      |> Jason.encode!()

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.ignored_level
    refute result.worker_mirrored
    assert is_nil(result.kyc_status)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
               ["appl-wrong-level"]
             ).rows

    assert [[nil, nil]] =
             Repo.query!(
               "SELECT kyc_status, sumsub_applicant_id FROM public.cleaner_applications WHERE id = $1",
               [Ecto.UUID.dump!(application_id)]
             ).rows
  end

  test "keeps GREEN when a later intermediate webhook arrives" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")

    {:ok, _} =
      Webhook.handle(
        Jason.encode!(reviewed_payload(user_id, "appl-2", "GREEN")),
        sign(Jason.encode!(reviewed_payload(user_id, "appl-2", "GREEN")))
      )

    on_hold = %{
      "type" => "applicantOnHold",
      "applicantId" => "appl-2",
      "externalUserId" => user_id,
      "reviewStatus" => "onHold",
      "createdAtMs" => 1_700_000_000_100
    }

    raw = Jason.encode!(on_hold)
    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.kyc_status == "completed"

    [[kyc_status, review_answer, last_event]] =
      Repo.query!(
        "SELECT kyc_status, review_answer, last_event_type FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-2"]
      ).rows

    assert kyc_status == "completed"
    assert review_answer == "GREEN"
    assert last_event == "applicantOnHold"
  end

  test "keeps GREEN when applicantAwaitingUser arrives later" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "worker@tryinstaclean.com", "+233555000111")

    green = Jason.encode!(reviewed_payload(user_id, "appl-await", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(green, sign(green))

    raw =
      Jason.encode!(%{
        "type" => "applicantAwaitingUser",
        "applicantId" => "appl-await",
        "externalUserId" => user_id,
        "createdAtMs" => 150
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.kyc_status == "completed"
  end

  test "applicantActionReviewed GREEN completes KYC" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "worker@tryinstaclean.com", "+233555000111")

    raw =
      Jason.encode!(%{
        "type" => "applicantActionReviewed",
        "applicantId" => "appl-action",
        "externalUserId" => user_id,
        "levelName" => "id-and-liveness",
        "reviewResult" => %{"reviewAnswer" => "GREEN"},
        "createdAtMs" => 100
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.kyc_status == "completed"
  end

  test "applicantReset starts KYC over after GREEN" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "worker@tryinstaclean.com", "+233555000111")

    green = Jason.encode!(reviewed_payload(user_id, "appl-reset", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(green, sign(green))

    raw =
      Jason.encode!(%{
        "type" => "applicantReset",
        "applicantId" => "appl-reset",
        "externalUserId" => user_id,
        "createdAtMs" => 200
      })

    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    refute result.skipped_stale
    assert result.kyc_status == "started"
  end

  test "duplicate identical webhooks are idempotent" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")
    raw = Jason.encode!(reviewed_payload(user_id, "appl-dup", "GREEN", 100))

    assert {:ok, first} = Webhook.handle(raw, sign(raw))
    assert first.kyc_status == "completed"

    [[reviewed_at, completed_at, updated_at]] =
      Repo.query!(
        """
        SELECT reviewed_at, completed_at, updated_at
        FROM public.kyc_profiles
        WHERE sumsub_applicant_id = $1
        """,
        ["appl-dup"]
      ).rows

    assert {:ok, second} = Webhook.handle(raw, sign(raw))
    assert second.kyc_status == "completed"
    assert second.skipped_stale

    [[retry_reviewed_at, retry_completed_at, retry_updated_at]] =
      Repo.query!(
        """
        SELECT reviewed_at, completed_at, updated_at
        FROM public.kyc_profiles
        WHERE sumsub_applicant_id = $1
        """,
        ["appl-dup"]
      ).rows

    assert retry_reviewed_at == reviewed_at
    assert retry_completed_at == completed_at
    assert retry_updated_at == updated_at

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
               ["appl-dup"]
             ).rows
  end

  test "ignores an older applicantReviewed that would overwrite a newer RED" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")

    red = Jason.encode!(reviewed_payload(user_id, "appl-order", "RED", 200))
    assert {:ok, _} = Webhook.handle(red, sign(red))

    green = Jason.encode!(reviewed_payload(user_id, "appl-order", "GREEN", 100))
    assert {:ok, result} = Webhook.handle(green, sign(green))
    assert result.skipped_stale
    assert result.kyc_status == "rejected"

    [[kyc_status, review_answer, last_ms]] =
      Repo.query!(
        "SELECT kyc_status, review_answer, last_event_created_at_ms FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-order"]
      ).rows

    assert kyc_status == "rejected"
    assert review_answer == "RED"
    assert last_ms == 200
  end

  test "orders provider timestamp strings before stale-event checks" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "provider-time@tryinstaclean.com", "+233555000111")

    newer =
      reviewed_payload(
        user_id,
        "appl-provider-time",
        "RED",
        "2021-05-14 16:00:25.032"
      )
      |> Jason.encode!()

    assert {:ok, _} = Webhook.handle(newer, sign(newer))

    delayed =
      reviewed_payload(
        user_id,
        "appl-provider-time",
        "GREEN",
        "2021-05-14 16:00:24.999"
      )
      |> Jason.encode!()

    assert {:ok, result} = Webhook.handle(delayed, sign(delayed))
    assert result.skipped_stale
    assert result.kyc_status == "rejected"

    [[kyc_status, review_answer, last_ms]] =
      Repo.query!(
        """
        SELECT kyc_status, review_answer, last_event_created_at_ms
        FROM public.kyc_profiles
        WHERE sumsub_applicant_id = $1
        """,
        ["appl-provider-time"]
      ).rows

    assert kyc_status == "rejected"
    assert review_answer == "RED"
    assert last_ms == 1_621_008_025_032
  end

  test "rejects a signed payload without a provider timestamp" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "missing-time@tryinstaclean.com", "+233555000111")

    raw =
      reviewed_payload(user_id, "appl-missing-time", "GREEN")
      |> Map.delete("createdAtMs")
      |> Jason.encode!()

    assert {:error, :invalid_payload} = Webhook.handle(raw, sign(raw))
  end

  test "applies a newer RED after GREEN" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")

    green = Jason.encode!(reviewed_payload(user_id, "appl-newer", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(green, sign(green))

    red = Jason.encode!(reviewed_payload(user_id, "appl-newer", "RED", 200))
    assert {:ok, result} = Webhook.handle(red, sign(red))
    refute result.skipped_stale
    assert result.kyc_status == "rejected"
  end

  test "stale worker_application_id does not roll back the KYC write" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id, "cleaner@tryinstaclean.com", "+233555000111")

    Repo.query!(
      """
      INSERT INTO public.kyc_profiles (
        user_id, subject_type, sumsub_applicant_id, sumsub_external_user_id, kyc_status
      ) VALUES ($1, 'customer', 'appl-stale-app', $2, 'started')
      """,
      [Ecto.UUID.dump!(user_id), user_id]
    )

    Repo.query!(
      "UPDATE public.kyc_profiles SET cleaner_application_id = $1 WHERE sumsub_applicant_id = $2",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), "appl-stale-app"]
    )

    raw = Jason.encode!(reviewed_payload(user_id, "appl-stale-app", "GREEN", 300))
    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    assert result.kyc_status == "completed"
    refute result.worker_mirrored

    [[kyc_status]] =
      Repo.query!(
        "SELECT kyc_status FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-stale-app"]
      ).rows

    assert kyc_status == "completed"
  end

  test "contact fallback never takes an application owned by another user" do
    owner_id = Ecto.UUID.generate()
    webhook_user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    shared_phone = "+233555000111"
    shared_email = "shared@tryinstaclean.com"

    insert_user!(owner_id, "owner@tryinstaclean.com", "+233555000222")
    insert_user!(webhook_user_id, shared_email, shared_phone)
    insert_application!(application_id, owner_id, shared_email, shared_phone)

    raw = Jason.encode!(reviewed_payload(webhook_user_id, "appl-contact-owner", "GREEN", 100))
    assert {:ok, result} = Webhook.handle(raw, sign(raw))
    refute result.worker_mirrored

    [[stored_owner, applicant_id]] =
      Repo.query!(
        "SELECT user_id, sumsub_applicant_id FROM public.cleaner_applications WHERE id = $1",
        [Ecto.UUID.dump!(application_id)]
      ).rows

    assert stored_owner == Ecto.UUID.dump!(owner_id)
    assert is_nil(applicant_id)
  end

  test "orders stale events across replacement applicant ids" do
    user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    insert_user!(user_id, "replace@tryinstaclean.com", "+233555000111")
    insert_application!(application_id, user_id, "replace@tryinstaclean.com", "+233555000111")

    old_green = Jason.encode!(reviewed_payload(user_id, "appl-old", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(old_green, sign(old_green))

    new_red = Jason.encode!(reviewed_payload(user_id, "appl-new", "RED", 200))
    assert {:ok, _} = Webhook.handle(new_red, sign(new_red))

    delayed_old = Jason.encode!(reviewed_payload(user_id, "appl-old", "GREEN", 150))
    assert {:ok, result} = Webhook.handle(delayed_old, sign(delayed_old))
    assert result.skipped_stale
    assert result.kyc_status == "rejected"

    [[applicant_id, status, answer]] =
      Repo.query!(
        """
        SELECT sumsub_applicant_id, kyc_status, kyc_review_answer
        FROM public.cleaner_applications
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(application_id)]
      ).rows

    assert applicant_id == "appl-new"
    assert status == "rejected"
    assert answer == "RED"

    [[verification_status]] =
      Repo.query!(
        "SELECT status FROM public.cleaner_verifications WHERE id = $1",
        [Ecto.UUID.dump!(user_id)]
      ).rows

    assert verification_status == "rejected"
  end

  test "re-resolves a replacement worker application when the stored reference is gone" do
    user_id = Ecto.UUID.generate()
    old_application_id = Ecto.UUID.generate()
    replacement_application_id = Ecto.UUID.generate()
    insert_user!(user_id, "replacement@tryinstaclean.com", "+233555000111")

    insert_application!(
      old_application_id,
      user_id,
      "replacement@tryinstaclean.com",
      "+233555000111"
    )

    first = Jason.encode!(reviewed_payload(user_id, "appl-relink", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(first, sign(first))

    Repo.query!(
      "DELETE FROM public.cleaner_applications WHERE id = $1",
      [Ecto.UUID.dump!(old_application_id)]
    )

    insert_application!(
      replacement_application_id,
      user_id,
      "replacement@tryinstaclean.com",
      "+233555000111"
    )

    red = Jason.encode!(reviewed_payload(user_id, "appl-relink", "RED", 200))
    assert {:ok, result} = Webhook.handle(red, sign(red))
    assert result.worker_mirrored
    assert result.worker_application_id == Ecto.UUID.dump!(replacement_application_id)

    [[profile_application_id]] =
      Repo.query!(
        "SELECT cleaner_application_id FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-relink"]
      ).rows

    assert profile_application_id == Ecto.UUID.dump!(replacement_application_id)

    [[status, applicant_id]] =
      Repo.query!(
        "SELECT kyc_status, sumsub_applicant_id FROM public.cleaner_applications WHERE id = $1",
        [Ecto.UUID.dump!(replacement_application_id)]
      ).rows

    assert status == "rejected"
    assert applicant_id == "appl-relink"
  end

  test "revokes user verification when the linked worker application is gone" do
    user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    insert_user!(user_id, "orphaned@example.com", "+233555000111")
    insert_application!(application_id, user_id, "orphaned@example.com", "+233555000111")

    green = Jason.encode!(reviewed_payload(user_id, "appl-orphaned", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(green, sign(green))

    assert [["verified"]] =
             Repo.query!(
               "SELECT status FROM public.cleaner_verifications WHERE id = $1",
               [Ecto.UUID.dump!(user_id)]
             ).rows

    Repo.query!(
      "DELETE FROM public.cleaner_applications WHERE id = $1",
      [Ecto.UUID.dump!(application_id)]
    )

    red = Jason.encode!(reviewed_payload(user_id, "appl-orphaned", "RED", 200))
    assert {:ok, result} = Webhook.handle(red, sign(red))
    refute result.worker_mirrored
    assert is_nil(result.worker_application_id)

    assert [["rejected"]] =
             Repo.query!(
               "SELECT status FROM public.cleaner_verifications WHERE id = $1",
               [Ecto.UUID.dump!(user_id)]
             ).rows

    reset =
      Jason.encode!(%{
        "type" => "applicantReset",
        "applicantId" => "appl-orphaned",
        "externalUserId" => user_id,
        "createdAtMs" => 300
      })

    assert {:ok, _} = Webhook.handle(reset, sign(reset))

    assert [["unverified"]] =
             Repo.query!(
               "SELECT status FROM public.cleaner_verifications WHERE id = $1",
               [Ecto.UUID.dump!(user_id)]
             ).rows
  end

  test "clears completion metadata when a completed review is revoked" do
    user_id = Ecto.UUID.generate()
    application_id = Ecto.UUID.generate()
    insert_user!(user_id, "timestamps@tryinstaclean.com", "+233555000111")
    insert_application!(application_id, user_id, "timestamps@tryinstaclean.com", "+233555000111")

    green = Jason.encode!(reviewed_payload(user_id, "appl-timestamps", "GREEN", 100))
    assert {:ok, _} = Webhook.handle(green, sign(green))

    [[profile_completed_at, app_completed_at]] =
      Repo.query!(
        """
        SELECT k.completed_at, a.kyc_completed_at
        FROM public.kyc_profiles k
        JOIN public.cleaner_applications a ON a.id = k.cleaner_application_id
        WHERE k.sumsub_applicant_id = $1
        """,
        ["appl-timestamps"]
      ).rows

    refute is_nil(profile_completed_at)
    refute is_nil(app_completed_at)

    red = Jason.encode!(reviewed_payload(user_id, "appl-timestamps", "RED", 200))
    assert {:ok, _} = Webhook.handle(red, sign(red))

    [[profile_completed_at, app_completed_at, reviewed_at]] =
      Repo.query!(
        """
        SELECT k.completed_at, a.kyc_completed_at, k.reviewed_at
        FROM public.kyc_profiles k
        JOIN public.cleaner_applications a ON a.id = k.cleaner_application_id
        WHERE k.sumsub_applicant_id = $1
        """,
        ["appl-timestamps"]
      ).rows

    assert is_nil(profile_completed_at)
    assert is_nil(app_completed_at)
    refute is_nil(reviewed_at)

    reset =
      Jason.encode!(%{
        "type" => "applicantReset",
        "applicantId" => "appl-timestamps",
        "externalUserId" => user_id,
        "createdAtMs" => 300
      })

    assert {:ok, _} = Webhook.handle(reset, sign(reset))

    [[submitted_at, reviewed_at, completed_at]] =
      Repo.query!(
        """
        SELECT submitted_at, reviewed_at, completed_at
        FROM public.kyc_profiles
        WHERE sumsub_applicant_id = $1
        """,
        ["appl-timestamps"]
      ).rows

    assert is_nil(submitted_at)
    assert is_nil(reviewed_at)
    assert is_nil(completed_at)
  end

  test "rejects an applicant id reused for a different user" do
    first_user = Ecto.UUID.generate()
    second_user = Ecto.UUID.generate()
    insert_user!(first_user, "one@tryinstaclean.com", "+233555000111")
    insert_user!(second_user, "two@tryinstaclean.com", "+233555000222")

    raw = Jason.encode!(reviewed_payload(first_user, "appl-3", "GREEN"))
    assert {:ok, _} = Webhook.handle(raw, sign(raw))

    conflict = Jason.encode!(reviewed_payload(second_user, "appl-3", "GREEN"))
    assert {:error, :conflict} = Webhook.handle(conflict, sign(conflict))
  end

  defp reviewed_payload(user_id, applicant_id, answer, created_at_ms \\ 1_700_000_000_000) do
    %{
      "type" => "applicantReviewed",
      "applicantId" => applicant_id,
      "externalUserId" => user_id,
      "levelName" => "id-and-liveness",
      "reviewStatus" => "completed",
      "reviewResult" => %{"reviewAnswer" => answer},
      "createdAtMs" => created_at_ms
    }
  end

  defp sign(raw) do
    :hmac
    |> :crypto.mac(:sha256, "test-sumsub-webhook-secret", raw)
    |> Base.encode16(case: :lower)
  end

  defp insert_user!(id, email, phone) do
    Repo.query!(
      "INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(id), email, phone]
    )
  end

  defp insert_application!(id, user_id, email, phone) do
    Repo.query!(
      """
      INSERT INTO public.cleaner_applications (id, user_id, email, phone, name, bio, hourly_rate)
      VALUES ($1, $2, $3, $4, 'Ama', 'bio', 0)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(user_id), email, phone]
    )
  end

  defp recreate_tables do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate KYC fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- [
          "cleaner_verifications",
          "kyc_profiles",
          "cleaner_applications",
          "users"
        ] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_applications (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid,
      email text,
      phone text,
      name text NOT NULL DEFAULT 'applicant',
      bio text NOT NULL DEFAULT '',
      hourly_rate integer NOT NULL DEFAULT 0,
      kyc_provider text,
      sumsub_applicant_id text,
      sumsub_level_name text,
      kyc_status text,
      kyc_review_answer text,
      kyc_review_status text,
      kyc_provider_event text,
      kyc_last_event_at timestamptz,
      kyc_completed_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz
    )
    """)

    Repo.query!("""
    CREATE TABLE public.kyc_profiles (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      subject_type text NOT NULL,
      cleaner_application_id uuid,
      sumsub_applicant_id text NOT NULL UNIQUE,
      sumsub_external_user_id text NOT NULL,
      kyc_status text NOT NULL DEFAULT 'not_started',
      review_answer text,
      review_reason text,
      level_name text,
      country_code text,
      document_types text[],
      submitted_at timestamptz,
      reviewed_at timestamptz,
      completed_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      last_event_type text,
      last_event_created_at_ms bigint,
      last_webhook_payload jsonb
    )
    """)

    Repo.query!("""
    CREATE TABLE public.cleaner_verifications (
      id uuid PRIMARY KEY,
      user_id uuid,
      status text,
      updated_at timestamptz
    )
    """)
  end
end
