defmodule Mithril.ReplaceCleanerWeeklyAvailabilityTest do
  use ExUnit.Case, async: false

  alias Mithril.MobileFunctions.ReplaceCleanerWeeklyAvailability
  alias Mithril.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.availability (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      cleaner_id uuid,
      start_time timestamptz NOT NULL,
      end_time timestamptz NOT NULL,
      is_recurring boolean DEFAULT false,
      day_of_week integer,
      created_at timestamptz DEFAULT now()
    )
    """)

    :ok
  end

  test "rejects an empty week and a window that ends before it starts" do
    cleaner_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{error: "weekly_hours_empty"}}} =
             ReplaceCleanerWeeklyAvailability.call(cleaner_id, %{"windows" => []})

    assert {:error, {:status, 400, %{error: "weekly_hours_invalid"}}} =
             ReplaceCleanerWeeklyAvailability.call(cleaner_id, %{
               "windows" => [
                 %{"day_of_week" => 1, "start_time" => "17:00", "end_time" => "08:00"}
               ]
             })
  end

  test "replaces the signed-in cleaner's week in one save" do
    cleaner_id = Ecto.UUID.generate()

    assert {:ok, %{"windows" => first}} =
             ReplaceCleanerWeeklyAvailability.call(cleaner_id, %{
               "windows" => [
                 %{"day_of_week" => 1, "start_time" => "08:00", "end_time" => "17:00"},
                 %{"day_of_week" => 0, "start_time" => "09:00", "end_time" => "13:00"}
               ]
             })

    assert first == [
             %{"day_of_week" => 0, "start_time" => "09:00", "end_time" => "13:00"},
             %{"day_of_week" => 1, "start_time" => "08:00", "end_time" => "17:00"}
           ]

    assert {:ok, %{"windows" => replaced}} =
             ReplaceCleanerWeeklyAvailability.call(cleaner_id, %{
               "windows" => [
                 %{"day_of_week" => 1, "start_time" => "10:00", "end_time" => "16:00"}
               ]
             })

    assert replaced == [
             %{"day_of_week" => 1, "start_time" => "10:00", "end_time" => "16:00"}
           ]

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM public.availability WHERE cleaner_id = $1::uuid",
               [Ecto.UUID.dump!(cleaner_id)]
             )
  end
end
