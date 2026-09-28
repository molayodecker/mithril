defmodule Mithril.ScheduledJobs.CleanupStaleGhanaCardUploadsTest do
  use ExUnit.Case, async: false

  alias Mithril.ObjectStorage.TestDouble
  alias Mithril.ScheduledJobs.CleanupStaleGhanaCardUploads
  alias Mithril.StorageCleanup.GhanaCard

  setup do
    {:ok, _pid} = TestDouble.start_link()
    Application.put_env(:mithril, :object_storage_backend, TestDouble)
    on_exit(fn -> Application.delete_env(:mithril, :object_storage_backend) end)
    TestDouble.reset!()
    :ok
  end

  test "orphan storage prefix is removed while referenced ids are excluded from orphan list" do
    referenced = Ecto.UUID.generate()
    orphan = Ecto.UUID.generate()
    bucket = "cleaner-ghana-card-id"

    TestDouble.put_listing(bucket, "ghana-cards", [%{"name" => referenced}, %{"name" => orphan}])
    TestDouble.put_recursive(bucket, "ghana-cards/#{orphan}", ["ghana-cards/#{orphan}/front.jpg"])

    existing = MapSet.new([referenced])
    orphans = GhanaCard.orphan_folder_ids([referenced, orphan], existing)
    assert orphans == [orphan]

    prefixes = GhanaCard.removal_prefixes(orphans, [], "ghana-cards", "recruitment")
    assert prefixes == ["ghana-cards/#{orphan}"]
  end

  test "missing object delete is harmless when storage returns ok" do
    assert :ok = TestDouble.remove_object("bucket", "missing/path.jpg")
    assert TestDouble.deleted_paths() == ["missing/path.jpg"]
  end

  test "job skips cleanly when storage is not configured" do
    Application.delete_env(:mithril, :object_storage_backend)
    Application.put_env(:mithril, :object_storage_backend, Mithril.SupabaseStorage)

    assert :ok = CleanupStaleGhanaCardUploads.run()
  end
end
