defmodule MithrilWeb.SumsubWebhookControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo

  @endpoint MithrilWeb.Endpoint
  @secret "test-sumsub-webhook-secret"

  setup do
    :ok = Sandbox.checkout(Repo)
    recreate_tables()
    :ok
  end

  test "POST /webhooks/sumsub accepts a signed applicantReviewed payload" do
    user_id = Ecto.UUID.generate()
    insert_user!(user_id)

    payload = %{
      "type" => "applicantReviewed",
      "applicantId" => "appl-http-1",
      "externalUserId" => user_id,
      "levelName" => "id-and-liveness",
      "reviewResult" => %{"reviewAnswer" => "GREEN"},
      "createdAtMs" => "2021-05-14 16:00:25.032"
    }

    raw = Jason.encode!(payload)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-payload-digest", sign(raw))
      |> post("/webhooks/sumsub", raw)

    assert %{
             "ok" => true,
             "applicantId" => "appl-http-1",
             "externalUserId" => ^user_id,
             "kycStatus" => "completed",
             "workerMirrored" => false,
             "skippedStale" => false
           } = json_response(conn, 200)
  end

  test "POST /webhooks/sumsub rejects a missing signature" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/sumsub", ~s({"type":"applicantCreated"}))

    assert %{"error" => "Invalid webhook signature"} = json_response(conn, 401)
  end

  test "POST /webhooks/sumsub rejects a bad signature" do
    raw =
      ~s({"type":"applicantCreated","applicantId":"a","externalUserId":"#{Ecto.UUID.generate()}"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-payload-digest", String.duplicate("a", 64))
      |> post("/webhooks/sumsub", raw)

    assert %{"error" => "Invalid webhook signature"} = json_response(conn, 401)
  end

  test "POST /webhooks/sumsub returns 503 when the secret is missing" do
    previous = Application.get_env(:mithril, :sumsub_webhook_secret)
    Application.delete_env(:mithril, :sumsub_webhook_secret)

    on_exit(fn -> Application.put_env(:mithril, :sumsub_webhook_secret, previous) end)

    raw = ~s({"type":"applicantCreated"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-payload-digest", sign(raw))
      |> post("/webhooks/sumsub", raw)

    assert %{"error" => "Missing SUMSUB_WEBHOOK_SECRET"} = json_response(conn, 503)
  end

  defp sign(raw) do
    :hmac
    |> :crypto.mac(:sha256, @secret, raw)
    |> Base.encode16(case: :lower)
  end

  defp insert_user!(id) do
    Repo.query!(
      "INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(id), "kyc@tryinstaclean.com", "+233555000111"]
    )
  end

  defp recreate_tables do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate KYC fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["cleaner_verifications", "kyc_profiles", "cleaner_applications", "users"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("CREATE TABLE public.users (id uuid PRIMARY KEY, email text, phone text)")

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
      last_state_event_created_at_ms bigint,
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
