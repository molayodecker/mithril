defmodule Mithril.Bookings do
  @moduledoc """
  Read-only access to booking data while Instaclean migrates from Supabase.

  Write operations intentionally do not exist in this context yet.
  """

  alias Mithril.Bookings.Booking
  alias Mithril.Repo

  @spec get_booking(String.t()) :: {:ok, Booking.t()} | {:error, :invalid_id | :not_found}
  def get_booking(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Booking{} = booking <- Repo.get(Booking, uuid) do
      {:ok, booking}
    else
      :error -> {:error, :invalid_id}
      nil -> {:error, :not_found}
    end
  end
end
