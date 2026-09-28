defmodule Mithril.StorageCleanup.GhanaCardTest do
  use ExUnit.Case, async: true

  alias Mithril.StorageCleanup.GhanaCard

  setup do
    user_id = Ecto.UUID.generate()
    lead_id = Ecto.UUID.generate()
    orphan_id = Ecto.UUID.generate()

    {:ok, user_id: user_id, lead_id: lead_id, orphan_id: orphan_id}
  end

  test "child_folder_ids keeps only uuid folder names", %{user_id: user_id} do
    children = [
      %{"name" => user_id},
      %{"name" => "not-a-uuid"},
      %{"name" => "  "}
    ]

    assert GhanaCard.child_folder_ids(children) == [user_id]
  end

  test "referenced object is preserved", %{user_id: user_id, orphan_id: orphan_id} do
    existing = MapSet.new([user_id])
    orphans = GhanaCard.orphan_folder_ids([user_id, orphan_id], existing)
    assert orphans == [orphan_id]
  end

  test "removal_prefixes maps orphan folders to storage paths", %{orphan_id: orphan_id} do
    prefixes =
      GhanaCard.removal_prefixes([orphan_id], [], "ghana-cards", "recruitment")

    assert prefixes == ["ghana-cards/#{orphan_id}"]
  end
end
