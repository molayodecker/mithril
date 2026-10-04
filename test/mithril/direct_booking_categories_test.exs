defmodule Mithril.DirectBookingCategoriesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectBookings
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    create_catalog_fixtures!()
    :ok
  end

  test "lists categories with active services or no services and omits inactive-only and hidden categories" do
    insert_category!(1, "Empty", "empty", 1)
    insert_category!(2, "Active", "active", 2)
    insert_category!(3, "Inactive", "inactive", 3)
    insert_category!(4, "Cooks", "cooks", 4)

    insert_service!(2, true)
    insert_service!(3, false)
    insert_service!(4, true)

    assert {:ok, categories} = DirectBookings.list_categories()

    assert Enum.map(categories, & &1["name"]) == ["Empty", "Active"]
  end

  test "fails closed when a catalog visibility function is missing" do
    insert_category!(1, "Cooks", "cooks", 1)
    insert_service!(1, true)

    Repo.query!("DROP FUNCTION public.is_cooks_catalog_visible()")

    assert {:error, :database_unavailable} = DirectBookings.list_categories()
  end

  defp create_catalog_fixtures! do
    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")
    Repo.query!("DROP TABLE IF EXISTS public.service_categories CASCADE")

    for name <- [
          "is_care_pet_catalog_visible",
          "is_airbnb_catalog_visible",
          "is_quick_tasks_catalog_visible",
          "is_cooks_catalog_visible",
          "is_drivers_catalog_visible"
        ] do
      Repo.query!("DROP FUNCTION IF EXISTS public.#{name}()")
    end

    Repo.query!("""
    CREATE TABLE public.service_categories (
      id integer PRIMARY KEY,
      name text NOT NULL,
      icon text,
      slug text,
      weight integer,
      description text,
      image_url text,
      icon_scale numeric
    )
    """)

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      category_id integer REFERENCES public.service_categories(id),
      active boolean NOT NULL DEFAULT true
    )
    """)

    create_visibility_function!("is_care_pet_catalog_visible", true)
    create_visibility_function!("is_airbnb_catalog_visible", true)
    create_visibility_function!("is_quick_tasks_catalog_visible", true)
    create_visibility_function!("is_cooks_catalog_visible", false)
    create_visibility_function!("is_drivers_catalog_visible", true)
  end

  defp create_visibility_function!(name, visible) do
    Repo.query!("""
    CREATE FUNCTION public.#{name}()
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$ SELECT #{visible} $$
    """)
  end

  defp insert_category!(id, name, slug, weight) do
    Repo.query!(
      """
      INSERT INTO public.service_categories (id, name, slug, weight)
      VALUES ($1, $2, $3, $4)
      """,
      [id, name, slug, weight]
    )
  end

  defp insert_service!(category_id, active) do
    Repo.query!(
      "INSERT INTO public.service_types (category_id, active) VALUES ($1, $2)",
      [category_id, active]
    )
  end
end
