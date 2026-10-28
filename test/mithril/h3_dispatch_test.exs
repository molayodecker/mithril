defmodule Mithril.H3DispatchTest do
  use ExUnit.Case, async: false

  alias Mithril.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a job cell covers cleaners inside the radius and leaves distant cells out" do
    unless h3_dispatch_installed?() do
      # GitHub's Postgres image does not ship h3-pg. Local mithril_test does.
      assert true
    else
      assert %{rows: [[origin]]} =
               Repo.query!("""
               SELECT public.h3_cell_for_lat_lng(5.6037, -0.187)::text
               """)

      assert origin == "887576970bfffff"

      assert %{rows: [[near_inside, far_inside]]} =
               Repo.query!("""
               SELECT
                 public.h3_cell_for_lat_lng(5.6037 + (500.0 / 111320), -0.187) IN (
                   SELECT public.h3_dispatch_disk(5.6037, -0.187, 10000)
                 ),
                 public.h3_cell_for_lat_lng(5.6037 + (40000.0 / 111320), -0.187) IN (
                   SELECT public.h3_dispatch_disk(5.6037, -0.187, 10000)
                 )
               """)

      assert near_inside
      refute far_inside

      assert %{rows: [[nil]]} =
               Repo.query!("SELECT public.h3_cell_for_lat_lng(91, 0)::text")
    end
  end

  defp h3_dispatch_installed? do
    %{rows: [[function_name]]} =
      Repo.query!("""
      SELECT to_regprocedure(
        'public.h3_dispatch_disk(double precision, double precision, integer)'
      )::text
      """)

    is_binary(function_name)
  end
end
