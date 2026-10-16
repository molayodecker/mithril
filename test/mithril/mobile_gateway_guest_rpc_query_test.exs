defmodule Mithril.MobileGatewayGuestRpcQueryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileGateway
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    stub_guest_reads!()
    :ok
  end

  test "runs an allowlisted read without assuming a user" do
    assert {:ok, %{"guest" => true, "sub" => sub}} =
             MobileGateway.call_guest_rpc("get_ai_match_settings", %{})

    assert sub in [nil, ""]
  end

  test "runs extra-task catalog reads for a missing action and get_all" do
    assert {:ok, %{"action" => "none"}} = MobileGateway.call_guest_rpc("manage_extra_tasks", %{})

    assert {:ok, %{"action" => "get_all"}} =
             MobileGateway.call_guest_rpc("manage_extra_tasks", %{"action" => "get_all"})
  end

  test "runs pricing preview when the cleaning scan id is absent or blank" do
    assert {:ok, %{"scan" => ""}} = MobileGateway.call_guest_rpc("compute_booking_pricing", %{})

    assert {:ok, %{"scan" => ""}} =
             MobileGateway.call_guest_rpc("compute_booking_pricing", %{
               "p_cleaning_scan_id" => ""
             })
  end

  defp stub_guest_reads! do
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate guest RPC fixtures; expected mithril_test, got #{inspect(database)}"
    end

    replace_function!("""
    CREATE FUNCTION public.get_ai_match_settings()
    RETURNS jsonb
    LANGUAGE sql
    AS $$
      SELECT jsonb_build_object(
        'guest', true,
        'sub', current_setting('request.jwt.claim.sub', true)
      )
    $$
    """)

    replace_function!("""
    CREATE FUNCTION public.manage_extra_tasks(action text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE sql
    AS $$
      SELECT jsonb_build_object('action', COALESCE(action, 'none'))
    $$
    """)

    replace_function!("""
    CREATE FUNCTION public.compute_booking_pricing(p_cleaning_scan_id text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE sql
    AS $$
      SELECT jsonb_build_object('scan', COALESCE(p_cleaning_scan_id, ''))
    $$
    """)
  end

  defp replace_function!(create_sql) do
    [name] =
      Regex.run(~r/CREATE FUNCTION public\.([a-z0-9_]+)/, create_sql, capture: :all_but_first)

    %{rows: overloads} =
      Repo.query!(
        """
        SELECT pg_catalog.pg_get_function_identity_arguments(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = $1
        """,
        [name]
      )

    Enum.each(overloads, fn [arguments] ->
      Repo.query!("DROP FUNCTION public.#{name}(#{arguments})")
    end)

    Repo.query!(create_sql)
  end
end
