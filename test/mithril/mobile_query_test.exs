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
                   "columns" => ["id"],
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
    refute sql =~ "users.email"
    refute sql =~ "users.password_hash"
  end

  test "rejects credential and private fields on users and profile embeds" do
    assert {:error, :forbidden} =
             MobileQuery.compile("cleaner-a", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id"],
               "embeds" => [
                 %{
                   "table" => "users",
                   "constraint" => "bookings_customer_id_fkey",
                   "columns" => ["id", "email"]
                 }
               ]
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("user-1", %{
               "table" => "users",
               "action" => "select",
               "columns" => ["password_hash"]
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("cleaner-a", %{
               "table" => "bookings",
               "action" => "select",
               "columns" => ["id"],
               "embeds" => [
                 %{
                   "table" => "users",
                   "constraint" => "bookings_customer_id_fkey",
                   "columns" => ["id"],
                   "embeds" => [
                     %{
                       "table" => "profiles",
                       "columns" => ["address", "location_wkt"]
                     }
                   ]
                 }
               ]
             })
  end

  test "directory and lifecycle tables cannot be mutated through the generic query" do
    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "jobs",
               "action" => "insert",
               "rows" => [%{"customer_id" => "customer-a", "status" => "completed"}]
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "kyc_profiles",
               "action" => "update",
               "patch" => %{"kyc_status" => "approved"}
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("user-1", %{
               "table" => "users",
               "action" => "update",
               "patch" => %{"password_hash" => "stolen"}
             })

    assert {:error, :forbidden} =
             MobileQuery.compile("customer-a", %{
               "table" => "properties",
               "action" => "update",
               "patch" => %{"customer_id" => "customer-b"}
             })
  end

  test "limits cleaner directory reads to public profile fields" do
    assert {:ok, %{sql: sql}} =
             MobileQuery.compile("user-1", %{
               "table" => "cleaner_data",
               "action" => "select",
               "columns" => ["*"]
             })

    assert sql =~ "jsonb_build_object"
    assert sql =~ "'user_id'"
    refute sql =~ "to_jsonb(cleaner_data)"

    assert {:error, :forbidden} =
             MobileQuery.compile("user-1", %{
               "table" => "cleaner_data",
               "action" => "select",
               "columns" => ["user_id", "bank_account"]
             })
  end

  test "redacts encrypted calendar feed URLs from every projection" do
    assert {:error, :forbidden} =
             MobileQuery.compile("owner-a", %{
               "table" => "property_calendar_feeds",
               "action" => "select",
               "columns" => ["feed_url_encrypted"]
             })

    assert {:ok, %{sql: sql}} =
             MobileQuery.compile("owner-a", %{
               "table" => "property_calendar_feeds",
               "action" => "select",
               "columns" => ["*"]
             })

    assert sql =~ "to_jsonb(property_calendar_feeds)"
    assert sql =~ "- 'feed_url_encrypted'"
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
