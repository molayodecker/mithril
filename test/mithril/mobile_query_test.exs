defmodule Mithril.MobileQueryTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileGateway
  alias Mithril.MobileQuery
  alias Mithril.MobileRpc

  test "compiles an equality filter as a bound parameter" do
    assert {:ok, %{sql: sql, params: ["booking-1", "user-1"]}} =
             MobileQuery.compile("user-1", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id", "status"],
               "filters" => [%{"op" => "eq", "column" => "id", "value" => "booking-1"}]
             })

    assert sql =~ "public.bookings"
    assert sql =~ "bookings.id::text = $1::text"
    assert sql =~ "bookings.customer_id::text = $2::text"
    assert sql =~ "bookings.cleaner_id::text = $2::text"
    refute sql =~ "user-1"
  end

  test "rejects unknown tables and unsafe identifiers" do
    assert {:error, :unknown_table} =
             MobileQuery.compile("user-1", %{"table" => "auth.users", "action" => "select"})

    assert {:error, :invalid_column} =
             MobileQuery.compile("user-1", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id;drop"]
             })
  end

  test "compiles an allowlisted embed" do
    assert {:ok, %{sql: sql}} =
             MobileQuery.compile("user-1", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id"],
               "embeds" => [
                 %{
                   "alias" => "service",
                   "table" => "service_types",
                   "columns" => ["name"]
                 }
               ]
             })

    assert sql =~ "public.service_types"
    assert sql =~ "service_types.id = bookings.service_id"
  end

  test "compiles a head count and an array contains filter" do
    assert {:ok, %{sql: sql, params: [["+233200000001"], "user-1"]}} =
             MobileQuery.compile("user-1", %{
               "table" => "auth_identity_lookup",
               "action" => "select",
               "head" => true,
               "columns" => ["id"],
               "filters" => [
                 %{"op" => "contains", "column" => "phone_variants", "value" => ["+233200000001"]}
               ]
             })

    assert sql =~ "count(*)::int"
    assert sql =~ "phone_variants::text[] @>"
    refute sql =~ "jsonb_agg"
  end

  test "compiles a nested embed inside the parent subquery" do
    assert {:ok, %{sql: sql}} =
             MobileQuery.compile("user-1", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id"],
               "embeds" => [
                 %{
                   "alias" => "customer",
                   "table" => "users",
                   "constraint" => "bookings_customer_id_fkey",
                   "columns" => ["id", "email"],
                   "embeds" => [
                     %{
                       "table" => "profiles",
                       "columns" => ["fullname"]
                     }
                   ]
                 }
               ]
             })

    assert sql =~ "public.users"
    assert sql =~ "public.profiles"
    assert sql =~ "profiles.id = users.id"
  end

  test "scopes a booking to the caller and refuses another customer's insert" do
    assert {:ok, %{sql: sql}} =
             MobileQuery.compile("customer-a", %{
               "table" => "kyc_profiles",
               "action" => "select",
               "columns" => ["id"]
             })

    assert sql =~ "kyc_profiles.user_id::text = $1::text"
    refute sql =~ "customer-a"

    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "bookings",
               "action" => "insert",
               "rows" => [%{"customer_id" => "customer-b"}]
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("cleaner-a", %{
               "table" => "platform_fees",
               "action" => "update",
               "patch" => %{"fee_bps" => 1},
               "filters" => [%{"op" => "eq", "column" => "id", "value" => "fee-1"}]
             })
  end

  test "generic gateway cannot mutate booking lifecycle fields or delete bookings" do
    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "bookings",
               "action" => "insert",
               "rows" => [%{"customer_id" => "customer-a", "payment_status" => "paid"}]
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "bookings",
               "action" => "update",
               "patch" => %{"status" => "completed", "payment_status" => "paid"}
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "bookings",
               "action" => "delete"
             })
  end

  test "profile directory reads are scoped to the signed-in profile" do
    assert {:ok, %{sql: sql, params: ["user-1"]}} =
             MobileQuery.compile("user-1", %{
               "table" => "profiles",
               "action" => "select",
               "columns" => ["address", "location_wkt"]
             })

    assert sql =~ "profiles.id::text = $1::text"
  end

  test "gateway rejects unsafe embedded user projections before querying" do
    assert {:error, :forbidden} =
             MobileGateway.run_query("cleaner-a", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id"],
               "embeds" => [
                 %{
                   "table" => "users",
                   "constraint" => "bookings_customer_id_fkey",
                   "columns" => ["password_hash"]
                 }
               ]
             })
  end

  test "gateway rejects encrypted calendar feed projections and mutation wildcard returning" do
    assert {:error, :forbidden} =
             MobileGateway.run_query("owner-a", %{
               "table" => "property_calendar_feeds",
               "action" => "select",
               "columns" => ["feed_url_encrypted"]
             })

    assert {:error, :forbidden} =
             MobileGateway.run_query("owner-a", %{
               "table" => "property_calendar_feeds",
               "action" => "update",
               "patch" => %{"name" => "Calendar"},
               "returning" => ["*"]
             })
  end

  test "rejects rpc names that are not allowlisted" do
    assert {:error, :unknown_function} = MobileRpc.compile("pg_read_file", %{})
  end

  test "compiles named rpc arguments" do
    assert {:ok, compiled} =
             MobileRpc.compile("accept_booking_assignment", %{"p_booking_id" => "abc"})

    assert MobileRpc.sql(compiled, :scalar) =~
             "to_jsonb(public.accept_booking_assignment(p_booking_id := $1))"
  end
end
