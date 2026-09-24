defmodule Mithril.Sumsub.ReconcileTest do
  use ExUnit.Case, async: true

  alias Mithril.Sumsub.Reconcile
  alias Mithril.Sumsub.SyncLookup

  test "derive_kyc_profile_kyc_status maps GREEN to completed" do
    assert Reconcile.derive_kyc_profile_kyc_status("GREEN", "completed") == "completed"
  end

  test "derive_kyc_profile_kyc_status maps init review status to started" do
    assert Reconcile.derive_kyc_profile_kyc_status(nil, "init") == "started"
  end

  test "map_kyc_profile_status_to_verification_status maps pending review" do
    assert Reconcile.map_kyc_profile_status_to_verification_status("pending") == "pending"
  end

  test "build_paths prefers latest linked kyc profile" do
    paths =
      SyncLookup.build_paths(
        [
          %{
            "sumsub_applicant_id" => "old-applicant",
            "sumsub_external_user_id" => "user-old",
            "sumsub_linked_at" => "2020-01-01T00:00:00Z"
          },
          %{
            "sumsub_applicant_id" => "new-applicant",
            "sumsub_external_user_id" => "user-new",
            "sumsub_linked_at" => "2025-01-01T00:00:00Z"
          }
        ],
        nil
      )

    assert hd(paths) == "/resources/applicants/new-applicant/one"
  end

  test "parse_applicant_envelope reads review fields" do
    assert SyncLookup.parse_applicant_envelope(%{
             "id" => "applicant-1",
             "review" => %{
               "reviewStatus" => "completed",
               "reviewResult" => %{"reviewAnswer" => "GREEN"}
             }
           }) == %{
             applicant_id: "applicant-1",
             review_status: "completed",
             review_answer: "GREEN"
           }
  end
end

defmodule Mithril.MobileFunctions.SumsubTokenTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.SumsubToken

  test "returns missing secrets error when Sumsub is not configured" do
    previous_token = Application.get_env(:mithril, :sumsub_app_token)
    previous_secret = Application.get_env(:mithril, :sumsub_secret_key)

    Application.delete_env(:mithril, :sumsub_app_token)
    Application.delete_env(:mithril, :sumsub_secret_key)

    on_exit(fn ->
      if previous_token, do: Application.put_env(:mithril, :sumsub_app_token, previous_token)
      if previous_secret, do: Application.put_env(:mithril, :sumsub_secret_key, previous_secret)
    end)

    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 500, body}} = SumsubToken.call(user_id, %{})
    assert body.error == "Identity verification is not configured"
    refute Map.has_key?(body, :missing)
  end
end

defmodule Mithril.Posthog.ReadFlagTest do
  use ExUnit.Case, async: true

  alias Mithril.Posthog

  test "read_boolean_flag supports flags map" do
    assert Posthog.read_boolean_flag(
             %{"flags" => %{"booking_uber_transportation_v1" => true}},
             "booking_uber_transportation_v1"
           )
  end
end

defmodule Mithril.MobileFunctions.CreateJobAndNotifyTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.CreateJobAndNotify

  test "validates required job fields" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, body}} =
             CreateJobAndNotify.call(user_id, %{"lat" => 5.0, "lng" => -0.2})

    assert body.error =~ "address_text"
  end

  test "rejects a zero or negative job price" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "Invalid price"}}} =
             CreateJobAndNotify.call(user_id, valid_job_body(%{"price" => 0}))
  end

  test "rejects an unbounded client-supplied job price" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "Invalid price"}}} =
             CreateJobAndNotify.call(user_id, valid_job_body(%{"price" => 500_001}))
  end

  test "rejects a scheduled_date in the past" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "scheduled_date must be today or later"}}} =
             CreateJobAndNotify.call(user_id, valid_job_body(%{"scheduled_date" => "2020-01-01"}))
  end

  defp valid_job_body(overrides) do
    Map.merge(
      %{
        "address_text" => "East Legon",
        "lat" => 5.65,
        "lng" => -0.18,
        "price" => 80,
        "scheduled_date" => "2026-10-01",
        "start_time" => "10:00",
        "duration_hours" => 2
      },
      overrides
    )
  end
end

defmodule Mithril.MobileFunctions.RankCleanersTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.RankCleanersWithAi

  test "returns deterministic fallback ranking" do
    assert {:ok, body} =
             RankCleanersWithAi.call(Ecto.UUID.generate(), %{
               "cleaners" => [
                 %{"id" => "b", "match_score" => 99},
                 %{"id" => "a", "match_score" => 1}
               ]
             })

    assert body.source == "fallback"
    assert hd(body.cleaners).cleaner_id == "a"
    assert Enum.all?(body.cleaners, fn cleaner -> cleaner.score == 0 end)
  end
end
