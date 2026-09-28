defmodule Mithril.StorageCleanup.QuickTaskTest do
  use ExUnit.Case, async: false

  alias Mithril.ObjectStorage.TestDouble
  alias Mithril.StorageCleanup.QuickTask

  setup do
    {:ok, _pid} = TestDouble.start_link()
    TestDouble.reset!()
    Application.put_env(:mithril, :object_storage_backend, TestDouble)
    on_exit(fn -> Application.delete_env(:mithril, :object_storage_backend) end)
    :ok
  end

  test "expired orphan paths are deleted idempotently" do
    paths = ["orphan/a.jpg", "orphan/b.jpg"]
    assert :ok = QuickTask.delete_paths(paths, "quick-task-photos")
    assert MapSet.new(TestDouble.deleted_paths()) == MapSet.new(paths)
    assert :ok = QuickTask.delete_paths(paths, "quick-task-photos")
  end

  test "delete API failure is retry-safe at the claim layer" do
    TestDouble.fail_delete("orphan/b.jpg")

    assert {:error, :storage_deletion_failed} =
             QuickTask.delete_paths(["orphan/a.jpg", "orphan/b.jpg"], "bucket")

    assert TestDouble.deleted_paths() == ["orphan/a.jpg"]
  end

  test "decode_claim parses paths from json map" do
    claim_id = Ecto.UUID.generate()

    assert %{paths: ["p1"], claim_id: ^claim_id} =
             QuickTask.decode_claim(%{"paths" => ["p1"], "claim_id" => claim_id})
  end

  test "batch continuation respects limit boundary" do
    assert QuickTask.should_continue_batch?(200, 200)
    refute QuickTask.should_continue_batch?(199, 200)
  end
end
