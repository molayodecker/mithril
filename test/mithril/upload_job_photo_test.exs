defmodule Mithril.MobileFunctions.UploadJobPhotoTest do
  use ExUnit.Case, async: false

  alias Mithril.JobPhotoStorage
  alias Mithril.JobPhotoStorage.TestDouble
  alias Mithril.MobileFunctions.UploadJobPhoto

  @booking_id "a06d0853-54f3-4f71-8fd2-a138fddb7087"
  @user_id "11111111-1111-4111-8111-111111111111"

  setup do
    start_supervised!(TestDouble)
    previous = Application.get_env(:mithril, :job_photo_storage_backend)
    Application.put_env(:mithril, :job_photo_storage_backend, TestDouble)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :job_photo_storage_backend, previous)
      else
        Application.delete_env(:mithril, :job_photo_storage_backend)
      end
    end)

    :ok
  end

  test "stores a job photo under the job-photos prefix" do
    assert {:ok, "job-photos/#{@booking_id}/1761580800000000-before.jpg"} =
             JobPhotoStorage.put(
               "#{@booking_id}/1761580800000000-before.jpg",
               "image-bytes",
               "image/jpeg"
             )

    assert TestDouble.uploads() == [
             {"job-photos/#{@booking_id}/1761580800000000-before.jpg", "image-bytes",
              "image/jpeg"}
           ]
  end

  test "rejects a path that escapes the booking folder before writing" do
    assert {:error, {:status, 400, %{error: "Invalid storage path"}}} =
             UploadJobPhoto.call(@user_id, %{
               "booking_id" => @booking_id,
               "photo_type" => "before",
               "storage_path" => "#{@booking_id}/../avatars/secret.jpg",
               "content_type" => "image/jpeg",
               "data_base64" => Base.encode64("image-bytes")
             })

    assert TestDouble.uploads() == []
  end

  test "rejects an image larger than 5MB before writing" do
    oversized = Base.encode64(:binary.copy("a", 5_000_001))

    assert {:error, {:status, 400, %{error: "Image must be less than 5MB."}}} =
             UploadJobPhoto.call(@user_id, %{
               "booking_id" => @booking_id,
               "photo_type" => "before",
               "storage_path" => "#{@booking_id}/1761580800000000-before.jpg",
               "content_type" => "image/jpeg",
               "data_base64" => oversized
             })

    assert TestDouble.uploads() == []
  end
end
