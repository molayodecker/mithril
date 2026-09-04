defmodule Mithril.Bookings.Booking do
  @moduledoc """
  Read-only Ecto mapping for the legacy `public.bookings` table.

  This intentionally maps only the stable fields required for the first
  Supabase-to-Mithril parity slice. Column types match the live Instaclean
  table (`service_id` integer, money/duration numeric). It does not own the
  table DDL yet.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "bookings" do
    field :customer_id, :binary_id
    field :cleaner_id, :binary_id
    field :service_id, :integer
    field :scheduled_date, :date
    field :scheduled_time, :time
    field :duration_hours, :decimal
    field :address, :string
    field :special_instructions, :string
    field :status, :string
    field :total_price, :decimal
    field :platform_fee, :decimal
    field :tax_amount, :decimal
    field :payment_status, :string
    field :payment_method, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
