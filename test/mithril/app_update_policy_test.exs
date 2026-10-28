defmodule Mithril.AppUpdatePolicyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.AppUpdatePolicy
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate app update policy fixtures; expected mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.app_update_policy CASCADE")

    Repo.query!("""
    CREATE TABLE public.app_update_policy (
      app text NOT NULL,
      channel text NOT NULL,
      min_version text NOT NULL,
      recommended_version text,
      required_message text NOT NULL,
      recommended_message text,
      updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
      PRIMARY KEY (app, channel)
    )
    """)

    Repo.query!("""
    INSERT INTO public.app_update_policy
      (app, channel, min_version, required_message)
    VALUES
      ('customer', 'production', '1.8.1', 'Update Instaclean to continue.')
    """)

    :ok
  end

  test "returns the one matching policy" do
    assert {:ok, policy} = AppUpdatePolicy.fetch("customer", "production")
    assert policy["app"] == "customer"
    assert policy["channel"] == "production"
    assert policy["min_version"] == "1.8.1"
    assert policy["recommended_version"] == nil
  end

  test "returns nil when that app has no row" do
    assert {:ok, nil} = AppUpdatePolicy.fetch("worker", "production")
  end

  test "rejects an unknown app or channel before querying" do
    assert {:error, :bad_request} = AppUpdatePolicy.fetch("admin", "production")
    assert {:error, :bad_request} = AppUpdatePolicy.fetch("customer", "beta")
    assert {:error, :bad_request} = AppUpdatePolicy.fetch(nil, nil)
  end
end
