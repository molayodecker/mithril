defmodule Mithril.DirectBookingsCategoriesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectBookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_category_tables!()
    :ok
  end

  test "lists categories by weight then name" do
    Repo.query!("""
    INSERT INTO public.service_categories (id, name, slug, weight)
    VALUES
      (1, 'Cleaning', 'cleaning', 70),
      (2, 'Pet Care', 'pet_care', 10),
      (3, 'Airbnb', 'airbnb', 10)
    """)

    assert {:ok, categories} = DirectBookings.list_categories()
    assert Enum.map(categories, & &1["slug"]) == ["airbnb", "pet_care", "cleaning"]
    assert hd(categories)["weight"] == 10
  end

  test "omits gated categories while their visibility functions are off" do
    Repo.query!("""
    INSERT INTO public.service_categories (id, name, slug, weight)
    VALUES
      (1, 'Cleaning', 'cleaning', 10),
      (2, 'Family Care', 'caregiving', 20),
      (3, 'Cooks', 'cooks', 30)
    """)

    Repo.query!(
      "CREATE OR REPLACE FUNCTION public.is_care_pet_catalog_visible() RETURNS boolean LANGUAGE sql AS $$ SELECT false $$"
    )

    Repo.query!(
      "CREATE OR REPLACE FUNCTION public.is_cooks_catalog_visible() RETURNS boolean LANGUAGE sql AS $$ SELECT false $$"
    )

    assert {:ok, categories} = DirectBookings.list_categories()
    assert Enum.map(categories, & &1["slug"]) == ["cleaning"]
  end

  defp create_category_tables! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate catalog fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.service_categories CASCADE")
    Repo.query!("DROP FUNCTION IF EXISTS public.is_care_pet_catalog_visible()")
    Repo.query!("DROP FUNCTION IF EXISTS public.is_airbnb_catalog_visible()")
    Repo.query!("DROP FUNCTION IF EXISTS public.is_quick_tasks_catalog_visible()")
    Repo.query!("DROP FUNCTION IF EXISTS public.is_cooks_catalog_visible()")
    Repo.query!("DROP FUNCTION IF EXISTS public.is_drivers_catalog_visible()")

    Repo.query!("""
    CREATE TABLE public.service_categories (
      id integer PRIMARY KEY,
      name text NOT NULL,
      icon text,
      slug text,
      weight integer NOT NULL DEFAULT 100,
      description text,
      image_url text,
      icon_scale numeric
    )
    """)

    for name <- [
          "is_care_pet_catalog_visible",
          "is_airbnb_catalog_visible",
          "is_quick_tasks_catalog_visible",
          "is_cooks_catalog_visible",
          "is_drivers_catalog_visible"
        ] do
      Repo.query!("""
      CREATE FUNCTION public.#{name}() RETURNS boolean
      LANGUAGE sql AS $$ SELECT true $$
      """)
    end
  end
end
