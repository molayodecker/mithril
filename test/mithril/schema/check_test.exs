defmodule Mithril.Schema.CheckTest do
  use ExUnit.Case, async: true

  alias Mithril.Schema.Check
  alias Mithril.Schema.RequiredTables

  test "required tables come from the Direct and auth schema" do
    tables = RequiredTables.tables()

    assert "oban_jobs" in tables
    assert "oban_peers" in tables
    assert "mithril_outbox" in tables
    assert "mithril_auth_accounts" in tables
    assert "direct_contract_letters" in tables
    refute "seed_service_types" in tables

    root = Path.expand("../../../priv/repo/sql", __DIR__)

    from_disk =
      [root, "{direct,auth}", "*.sql"]
      |> Path.join()
      |> Path.wildcard()
      |> RequiredTables.from_files()

    assert tables == from_disk
  end

  test "parses created tables and ignores comments" do
    sql = """
    -- CREATE TABLE public.commented_out (
    CREATE TABLE IF NOT EXISTS public.oban_jobs (
      id bigint
    );
    CREATE TABLE public.mithril_outbox (
      id bigint
    );
    """

    assert RequiredTables.tables_from_sql(sql) == ["oban_jobs", "mithril_outbox"]
  end

  test "fails when a required table is absent" do
    assert Check.verify(
             ["mithril_outbox", "oban_jobs"],
             {:ok, %{rows: [["mithril_outbox"]]}}
           ) == {:error, {:schema_missing, ["oban_jobs"]}}
  end

  test "passes when every required table is present" do
    assert Check.verify(
             ["oban_jobs", "oban_peers"],
             {:ok, %{rows: [["oban_peers"], ["oban_jobs"]]}}
           ) ==
             :ok
  end

  test "fails when the catalog query cannot be completed" do
    assert Check.verify(["oban_jobs"], {:error, :database_unavailable}) ==
             {:error, {:schema_check_failed, :database_unavailable}}

    assert Check.verify(["oban_jobs"], {:ok, %{rows: nil}}) ==
             {:error, {:schema_check_failed, :no_rows}}
  end
end
