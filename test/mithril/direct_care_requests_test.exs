defmodule Mithril.DirectCareRequestsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileGateway
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to create care-request fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("CREATE SCHEMA IF NOT EXISTS auth")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE AS $$
      SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
    $$
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.cleaner_data (
      user_id uuid PRIMARY KEY,
      verified boolean,
      status text,
      specialties text[]
    )
    """)

    execute_sql_file!("20261110064300_direct_care_requests.sql")
    :ok
  end

  test "a worker sees only open requests matched to their specialty" do
    customer_id = insert_user!()
    worker_id = insert_user!()
    other_id = insert_user!()
    insert_cleaner!(worker_id, ["Child_Care"])
    insert_cleaner!(other_id, ["private_chef"])

    assert {:ok, %{"success" => true, "care_request_id" => request_id}} =
             MobileGateway.call_rpc(customer_id, "create_direct_request", %{
               "p_category" => "family_care",
               "p_service_slug" => "child_care",
               "p_frequency" => "weekly",
               "p_budget_amount_major" => 2000,
               "p_budget_unit" => "per_month",
               "p_budget_negotiable" => true,
               "p_location_label" => "East Legon",
               "p_latitude" => 5.65,
               "p_longitude" => -0.15,
               "p_timezone_name" => "Africa/Accra",
               "p_notes" => "After school",
               "p_details" => %{"days" => ["mon"]}
             })

    assert {:ok, %{"success" => true, "requests" => [request]}} =
             MobileGateway.call_rpc(worker_id, "list_direct_requests_for_worker", %{})

    assert request["id"] == request_id
    assert request["specialty_slug"] == "child_care"
    assert request["budget_amount_minor"] == 200_000
    assert request["location_label"] == "East Legon"
    refute Map.has_key?(request, "latitude")
    refute Map.has_key?(request, "longitude")

    assert {:ok, %{"success" => true, "requests" => []}} =
             MobileGateway.call_rpc(other_id, "list_direct_requests_for_worker", %{})

    assert {:ok, %{"success" => true, "requests" => []}} =
             MobileGateway.call_rpc(customer_id, "list_direct_requests_for_worker", %{})

    assert {:ok, %{"success" => true, "request" => %{"id" => ^request_id}}} =
             MobileGateway.call_rpc(worker_id, "get_direct_request", %{
               "p_care_request_id" => request_id
             })

    assert {:ok, %{"success" => false, "error" => "not_found"}} =
             MobileGateway.call_rpc(other_id, "get_direct_request", %{
               "p_care_request_id" => request_id
             })

    assert {:ok, %{"success" => true}} =
             MobileGateway.call_rpc(worker_id, "respond_to_care_request", %{
               "p_care_request_id" => request_id,
               "p_offer_kind" => "accept",
               "p_amount_major" => nil,
               "p_note" => nil
             })

    assert {:ok, %{"success" => true, "requests" => []}} =
             MobileGateway.call_rpc(worker_id, "list_direct_requests_for_worker", %{})
  end

  defp insert_user! do
    user_id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO public.users (id) VALUES ($1)", [Ecto.UUID.dump!(user_id)])
    user_id
  end

  defp insert_cleaner!(user_id, specialties) do
    Repo.query!(
      """
      INSERT INTO public.cleaner_data (user_id, verified, status, specialties)
      VALUES ($1, true, 'active', $2)
      """,
      [Ecto.UUID.dump!(user_id), specialties]
    )
  end

  defp execute_sql_file!(name) do
    path = Path.expand("../../priv/repo/sql/direct/#{name}", __DIR__)

    path
    |> File.read!()
    |> sql_statements()
    |> Enum.each(&Repo.query!/1)
  end

  defp sql_statements(sql), do: scan_sql(sql, [], [], nil)

  defp scan_sql(<<>>, statements, current, nil) do
    statements |> finish_statement(current) |> Enum.reverse()
  end

  defp scan_sql(<<"$$", rest::binary>>, statements, current, nil) do
    scan_sql(rest, statements, ["$$" | current], "$$")
  end

  defp scan_sql(<<"$$", rest::binary>>, statements, current, "$$") do
    scan_sql(rest, statements, ["$$" | current], nil)
  end

  defp scan_sql(<<";", rest::binary>>, statements, current, nil) do
    scan_sql(rest, finish_statement(statements, current), [], nil)
  end

  defp scan_sql(<<char::utf8, rest::binary>>, statements, current, marker) do
    scan_sql(rest, statements, [<<char::utf8>> | current], marker)
  end

  defp finish_statement(statements, current) do
    statement = current |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

    if statement == "" do
      statements
    else
      [statement | statements]
    end
  end
end
