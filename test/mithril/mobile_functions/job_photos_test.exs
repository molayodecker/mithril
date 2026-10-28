defmodule Mithril.MobileFunctions.JobPhotosTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.JobPhotos

  test "rejects paths outside the requested booking before any storage operation" do
    booking = "123e4567-e89b-42d3-a456-426614174000"
    other = "123e4567-e89b-42d3-a456-426614174001"
    path = "#{other}/1760000000000000-before.jpg"

    for operation <- [&JobPhotos.upload/2, &JobPhotos.url/2, &JobPhotos.delete/2] do
      assert {:error, {:status, 400, %{error: "bad_request"}}} =
               operation.(booking, %{"booking_id" => booking, "storage_path" => path})
    end
  end

  test "rejects path traversal and unauthorized object prefixes" do
    booking = "123e4567-e89b-42d3-a456-426614174000"

    for path <- [
          "#{booking}/../secret.jpg",
          "#{booking}/comparisons/../../secret.png",
          "#{booking}/1760000000000000-before.jpg/extra",
          "#{booking}/1760000000000000-before.svg"
        ] do
      assert {:error, {:status, 400, %{error: "bad_request"}}} =
               JobPhotos.url(booking, %{"booking_id" => booking, "storage_path" => path})
    end
  end
end
