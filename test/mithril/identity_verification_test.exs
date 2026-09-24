defmodule Mithril.IdentityVerificationTest do
  use ExUnit.Case, async: true

  alias Mithril.IdentityVerification

  test "treats GREEN review_answer as verified" do
    row = %{"kyc_status" => "pending", "review_answer" => "GREEN"}
    assert IdentityVerification.kyc_row_verified?(row)
    assert IdentityVerification.derive_kyc_verification_status(row) == :verified
  end

  test "skips empty not_started placeholders when picking authoritative row" do
    rows = [
      %{
        "kyc_status" => "not_started",
        "review_answer" => nil,
        "updated_at" => ~U[2026-08-19 12:00:00Z]
      },
      %{
        "kyc_status" => "approved",
        "review_answer" => "GREEN",
        "updated_at" => ~U[2026-08-10 12:00:00Z]
      }
    ]

    authoritative =
      rows
      |> Enum.sort_by(fn row ->
        case row["updated_at"] do
          %DateTime{} = dt -> DateTime.to_unix(dt, :millisecond)
        end
      end, :desc)
      |> Enum.find(fn row -> not IdentityVerification.empty_legacy_kyc_placeholder?(row) end)

    assert IdentityVerification.kyc_row_verified?(authoritative)
  end

  test "detects empty not_started shell without applicant metadata" do
    assert IdentityVerification.empty_legacy_kyc_placeholder?(%{
             "kyc_status" => "not_started",
             "review_answer" => nil,
             "sumsub_applicant_id" => nil
           })
  end

  test "treats not_started with applicant id as authoritative unverified" do
    refute IdentityVerification.empty_legacy_kyc_placeholder?(%{
             "kyc_status" => "not_started",
             "sumsub_applicant_id" => "applicant-1"
           })
  end
end
