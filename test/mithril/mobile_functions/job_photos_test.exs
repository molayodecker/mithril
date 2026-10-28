defmodule Mithril.MobileFunctions.JobPhotosTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileFunctions.JobPhotos
  alias Mithril.Repo

  @booking "123e4567-e89b-42d3-a456-426614174000"
  @other "123e4567-e89b-42d3-a456-426614174001"
  @jpeg Base.encode64(<<0xFF, 0xD8, 0xFF, 0xD9, 0, 1, 2, 3>>)

  setup do
    :ok = Sandbox.checkout(Repo)
    create_tables!()
    :ok
  end

  test "rejects paths outside the requested booking before any storage operation" do
    path = "#{@other}/1760000000000000-before.jpg"

    for operation <- [&JobPhotos.upload/2, &JobPhotos.url/2, &JobPhotos.delete/2] do
      assert {:error, {:status, 400, %{error: "bad_request"}}} =
               operation.(@booking, %{"booking_id" => @booking, "storage_path" => path})
    end
  end

  test "rejects path traversal and unauthorized object prefixes" do
    for path <- [
          "#{@booking}/../secret.jpg",
          "#{@booking}/comparisons/../../secret.png",
          "#{@booking}/1760000000000000-before.jpg/extra",
          "#{@booking}/1760000000000000-before.svg"
        ] do
      assert {:error, {:status, 400, %{error: "bad_request"}}} =
               JobPhotos.url(@booking, %{"booking_id" => @booking, "storage_path" => path})
    end
  end

  test "only the assigned cleaner can write photos on an active booking" do
    {cleaner_id, customer_id, booking_id} = insert_booking!("in_progress")
    path = "#{booking_id}/1760000000000000-before.jpg"
    body = photo_body(booking_id, path)

    assert {:error, {:status, 403, %{error: "forbidden"}}} = JobPhotos.upload(customer_id, body)

    assert {:error, {:status, 403, %{error: "forbidden"}}} =
             JobPhotos.upload(Ecto.UUID.generate(), body)

    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             JobPhotos.upload(cleaner_id, body)
  end

  test "cancelled and completed bookings cannot receive new photos" do
    {cleaner_id, _customer_id, booking_id} = insert_booking!("cancelled")
    path = "#{booking_id}/1760000000000000-before.jpg"

    assert {:error, {:status, 403, %{error: "forbidden"}}} =
             JobPhotos.upload(cleaner_id, photo_body(booking_id, path))

    {done_cleaner, _customer_id, done_id} = insert_booking!("completed")

    assert {:error, {:status, 403, %{error: "forbidden"}}} =
             JobPhotos.upload(
               done_cleaner,
               photo_body(done_id, "#{done_id}/1760000000000000-after.jpg")
             )
  end

  test "rejects a content type that does not match the object extension" do
    {cleaner_id, _customer_id, booking_id} = insert_booking!("in_progress")
    path = "#{booking_id}/1760000000000000-before.jpg"

    assert {:error, {:status, 400, %{error: "invalid_photo"}}} =
             JobPhotos.upload(cleaner_id, %{
               "booking_id" => booking_id,
               "storage_path" => path,
               "content_type" => "image/png",
               "data_base64" => @jpeg
             })
  end

  test "refuses to delete a photo that is still registered" do
    {cleaner_id, _customer_id, booking_id} = insert_booking!("in_progress")
    path = "#{booking_id}/1760000000000000-before.jpg"
    insert_job_photo!(booking_id, cleaner_id, path)

    assert {:error, {:status, 400, %{error: "still_registered"}}} =
             JobPhotos.delete(cleaner_id, %{
               "booking_id" => booking_id,
               "storage_path" => path
             })
  end

  test "database lookup failure never authorizes R2 deletion" do
    {cleaner_id, _customer_id, booking_id} = insert_booking!("in_progress")
    path = "#{booking_id}/1760000000000000-before.jpg"
    insert_job_photo!(booking_id, cleaner_id, path)

    # Transactional DDL simulates a failed registration lookup without using R2.
    Repo.query!(
      "ALTER TABLE public.booking_job_photos RENAME TO booking_job_photos_unavailable_test"
    )

    # The SQL sandbox rolls back the table rename and failed lookup at test exit.
    assert {:error, {:status, 503, %{error: "database_unavailable"}}} =
             JobPhotos.delete(cleaner_id, %{
               "booking_id" => booking_id,
               "storage_path" => path
             })
  end

  test "customers can resolve a registered photo URL but cannot delete it" do
    {cleaner_id, customer_id, booking_id} = insert_booking!("in_progress")
    path = "#{booking_id}/1760000000000000-before.jpg"
    insert_job_photo!(booking_id, cleaner_id, path)

    assert {:error, {:status, 503, %{error: "storage_not_configured"}}} =
             JobPhotos.url(customer_id, %{
               "booking_id" => booking_id,
               "storage_path" => path
             })

    assert {:error, {:status, 403, %{error: "forbidden"}}} =
             JobPhotos.delete(customer_id, %{
               "booking_id" => booking_id,
               "storage_path" => path
             })
  end

  defp photo_body(booking_id, path) do
    %{
      "booking_id" => booking_id,
      "storage_path" => path,
      "content_type" => "image/jpeg",
      "data_base64" => @jpeg
    }
  end

  defp insert_booking!(status) do
    cleaner_id = Ecto.UUID.generate()
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO public.bookings (id, cleaner_id, customer_id, status, address)
      VALUES ($1, $2, $3, $4, 'East Legon')
      """,
      [
        Ecto.UUID.dump!(booking_id),
        Ecto.UUID.dump!(cleaner_id),
        Ecto.UUID.dump!(customer_id),
        status
      ]
    )

    {cleaner_id, customer_id, booking_id}
  end

  defp insert_job_photo!(booking_id, uploaded_by, path) do
    Repo.query!(
      """
      INSERT INTO public.booking_job_photos (booking_id, photo_type, storage_path, uploaded_by)
      VALUES ($1, 'before', $2, $3)
      """,
      [Ecto.UUID.dump!(booking_id), path, Ecto.UUID.dump!(uploaded_by)]
    )
  end

  defp create_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate tables; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.bookings (
      id uuid PRIMARY KEY,
      cleaner_id uuid,
      customer_id uuid,
      status text,
      address text
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.booking_job_photos (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid NOT NULL,
      photo_type text NOT NULL,
      storage_path text NOT NULL,
      uploaded_by uuid NOT NULL,
      caption text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)
  end
end
