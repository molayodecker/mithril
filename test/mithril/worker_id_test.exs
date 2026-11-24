defmodule Mithril.WorkerIdTest do
  use ExUnit.Case, async: false

  alias Mithril.WorkerId
  alias Mithril.WorkerIdPass

  @slug "abcd2345"

  test "a cleared active worker is active and the scan opens the id card" do
    card =
      WorkerId.card_from_row(%{
        slug: @slug,
        cleaner_status: "active",
        user_status: "active",
        categories: ["cleaning"],
        name: "Ama Mensah",
        photo_url: "https://cdn.example/ama.jpg",
        created_at: ~U[2025-03-04 12:00:00Z],
        review_answer: "GREEN",
        kyc_status: "completed"
      })

    assert card["statusLabel"] == "Active"
    assert card["active"]
    assert card["backgroundCleared"]
    assert card["idNumber"] == "IC-ABCD2345"
    assert card["verifyUrl"] == "https://worker.tryinstaclean.com/id/abcd2345"
    assert card["role"] == "Residential Cleaner"
    assert card["memberSince"] == "Mar 2025"
    assert card["photoUrl"] == "https://cdn.example/ama.jpg"
    refute Map.has_key?(card, "email")
    refute Map.has_key?(card, "phone")
    refute Map.has_key?(card, "documentNumber")
    refute Map.has_key?(card, "applicantId")
  end

  test "suspending the worker voids the pass and stops the card saying active" do
    card =
      WorkerId.card_from_row(%{
        slug: @slug,
        cleaner_status: "suspended",
        user_status: "active",
        categories: ["cleaning"],
        name: "Ama Mensah",
        photo_url: "avatars/ama.jpg",
        created_at: ~U[2025-03-04 12:00:00Z],
        review_answer: "GREEN",
        kyc_status: "completed"
      })

    assert card["statusLabel"] == "Suspended"
    refute card["active"]
    assert card["backgroundCleared"]
    assert card["photoUrl"] == nil

    pass = WorkerIdPass.pass_document(card, "pass-auth-token-value")
    assert pass["voided"]
    assert pass["serialNumber"] == @slug
    assert hd(pass["barcodes"])["message"] == "https://worker.tryinstaclean.com/id/abcd2345"
    status = Enum.find(pass["generic"]["secondaryFields"], &(&1["key"] == "status"))
    assert status["value"] == "Suspended"
    refute Map.has_key?(pass, "email")
  end

  test "a suspended account voids the pass even when the cleaner row is still active" do
    view =
      WorkerId.presentation(%{
        cleaner_status: "active",
        user_status: "suspended",
        review_answer: "GREEN",
        kyc_status: "completed"
      })

    assert view.void_pass
    assert view.status_label == "Suspended"
    refute view.active
  end

  test "an active pass is not voided" do
    card =
      WorkerId.card_from_row(%{
        slug: @slug,
        cleaner_status: "active",
        user_status: "active",
        categories: [],
        name: "Ama Mensah",
        photo_url: nil,
        created_at: nil,
        review_answer: "GREEN",
        kyc_status: nil
      })

    pass = WorkerIdPass.pass_document(card, "pass-auth-token-value")
    refute Map.has_key?(pass, "voided")
    refute Map.has_key?(pass, "logoText")

    assert pass["generic"]["secondaryFields"]
           |> Enum.find(&(&1["key"] == "status"))
           |> Map.get("value") ==
             "Active"
  end

  test "the pass header uses the wordmark instead of a solid logo block" do
    assets = WorkerIdPass.pass_assets()

    assert Enum.sort(Map.keys(assets)) == [
             "icon.png",
             "icon@2x.png",
             "icon@3x.png",
             "logo.png",
             "logo@2x.png",
             "logo@3x.png"
           ]

    assert <<_png_header::binary-size(16), logo_width::32, logo_height::32, _rest::binary>> =
             assets["logo.png"]

    assert logo_width > logo_height

    assert <<_icon_header::binary-size(16), icon_width::32, icon_height::32, _icon_rest::binary>> =
             assets["icon.png"]

    assert icon_width == icon_height
  end

  test "a review that is not cleared stays pending" do
    view =
      WorkerId.presentation(%{
        cleaner_status: "active",
        user_status: "active",
        review_answer: "RED",
        kyc_status: "rejected"
      })

    refute view.active
    refute view.background_cleared
    refute view.void_pass
    assert view.status_label == "Pending"
  end

  test "a PEM secret is written to a private file and a real path is left as a path" do
    dir = Path.join(System.tmp_dir!(), "worker-id-secret-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    existing = Path.join(dir, "already.pem")
    File.write!(existing, "existing")

    assert WorkerIdPass.materialize_secret(existing, "pass.pem") == existing

    path =
      WorkerIdPass.materialize_secret(
        "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----",
        "worker-id-test.pem"
      )

    assert File.regular?(path)
    assert File.read!(path) =~ "-----BEGIN CERTIFICATE-----"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    File.rm_rf!(dir)
  end

  test "wallet update cursor preserves two changes in the same second" do
    earlier = ~U[2026-11-20 10:00:00.100000Z]
    later = ~U[2026-11-20 10:00:00.200000Z]

    assert WorkerIdPass.cursor_microseconds(later) >
             WorkerIdPass.cursor_microseconds(earlier)

    assert WorkerIdPass.cursor_microseconds(later) -
             WorkerIdPass.cursor_microseconds(earlier) == 100_000
  end

  test "repeated PEM materialization never truncates a shared file" do
    pem = "-----BEGIN CERTIFICATE-----\\nZmFrZQ==\\n-----END CERTIFICATE-----"

    paths =
      1..12
      |> Task.async_stream(
        fn _ ->
          WorkerIdPass.materialize_secret(pem, "shared-pass-test.pem")
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, path} -> path end)

    assert Enum.uniq(paths) |> length() == 1
    assert File.read!(hd(paths)) == pem <> "\n"
    assert Bitwise.band(File.stat!(hd(paths)).mode, 0o777) == 0o600
  end

  test "the sync secret is compared in full and missing config does not authorize" do
    refute WorkerIdPass.authorized_sync?(nil)
    refute WorkerIdPass.authorized_sync?("Bearer short")
    System.put_env("WORKER_ID_SYNC_SECRET", "sync-secret-value")

    on_exit(fn -> System.delete_env("WORKER_ID_SYNC_SECRET") end)

    assert WorkerIdPass.authorized_sync?("Bearer sync-secret-value")
    refute WorkerIdPass.authorized_sync?("Bearer sync-secret-valu")
    refute WorkerIdPass.authorized_sync?("Bearer other-secret-value")
  end
end
