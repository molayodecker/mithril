defmodule Mithril.Transport.ReviewSelections do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Repo

  @ttl_seconds 15 * 60
  @dest_epsilon 0.0005

  @spec remember(term(), list(), map()) :: :ok
  def remember(customer_id, cleaner_ids, dest)
      when is_binary(customer_id) and is_list(cleaner_ids) and is_map(dest) do
    case dump_uuid(customer_id) do
      nil ->
        :ok

      dumped_customer ->
        expires_at = DateTime.utc_now() |> DateTime.add(@ttl_seconds, :second)

        Enum.each(cleaner_ids, fn cleaner_id ->
          remember_one(dumped_customer, cleaner_id, dest, expires_at)
        end)

        :ok
    end
  end

  def remember(_customer_id, _cleaner_ids, _dest), do: :ok

  @spec fetch(String.t(), String.t()) ::
          {:ok, %{latitude: float(), longitude: float()}}
          | {:error, :not_found}
          | {:error, :unavailable}
  def fetch(customer_id, cleaner_id)
      when is_binary(customer_id) and is_binary(cleaner_id) do
    case Repo.query(
           """
           SELECT latitude, longitude
           FROM public.transport_review_selections
           WHERE customer_id = $1::uuid
             AND cleaner_id = $2::uuid
             AND expires_at > now()
           LIMIT 1
           """,
           [DbUuid.dump!(customer_id), DbUuid.dump!(cleaner_id)]
         ) do
      {:ok, %{rows: [[latitude, longitude]]}} ->
        {:ok, %{latitude: latitude * 1.0, longitude: longitude * 1.0}}

      {:ok, _} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  @spec lock(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def lock(customer_id, cleaner_id)
      when is_binary(customer_id) and is_binary(cleaner_id) do
    case Repo.query(
           """
           SELECT 1
           FROM public.transport_review_selections
           WHERE customer_id = $1::uuid
             AND cleaner_id = $2::uuid
             AND expires_at > now()
           FOR UPDATE
           """,
           [DbUuid.dump!(customer_id), DbUuid.dump!(cleaner_id)]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, _} -> {:error, :not_found}
      {:error, _} -> {:error, :unavailable}
    end
  end

  @spec same_destination?(map(), float(), float()) :: boolean()
  def same_destination?(%{latitude: stored_lat, longitude: stored_lng}, latitude, longitude) do
    abs(stored_lat - latitude) <= @dest_epsilon and abs(stored_lng - longitude) <= @dest_epsilon
  end

  defp remember_one(dumped_customer, cleaner_id, dest, expires_at) do
    case dump_uuid(cleaner_id) do
      nil ->
        :ok

      dumped_cleaner ->
        _ =
          Repo.query(
            """
            INSERT INTO public.transport_review_selections (
              customer_id, cleaner_id, latitude, longitude, expires_at
            ) VALUES ($1::uuid, $2::uuid, $3, $4, $5::timestamptz)
            ON CONFLICT (customer_id, cleaner_id)
            DO UPDATE SET
              latitude = EXCLUDED.latitude,
              longitude = EXCLUDED.longitude,
              expires_at = EXCLUDED.expires_at
            """,
            [
              dumped_customer,
              dumped_cleaner,
              dest.latitude,
              dest.longitude,
              expires_at
            ]
          )

        :ok
    end
  end

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> DbUuid.dump!(uuid)
      :error -> nil
    end
  end

  defp dump_uuid(_), do: nil
end
