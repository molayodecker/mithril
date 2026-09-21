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
      "reviewStatus" => "onHold"
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
    assert {:ok, second} = Webhook.handle(raw, sign(raw))
    assert first.kyc_status == "completed"
    assert second.kyc_status == "completed"
    refute second.skipped_stale

    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM public.kyc_profiles WHERE sumsub_applicant_id = $1",
        ["appl-dup"]
      ).rows

    assert count == 1
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
