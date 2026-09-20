defmodule Mithril.DirectAdminAppUpdatePolicyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminAppUpdatePolicy
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate app update policy fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["app_update_policy", "user_roles", "users"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text,
      phone text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.app_update_policy (
      channel text PRIMARY KEY,
      min_version text NOT NULL,
      recommended_version text,
      required_message text NOT NULL DEFAULT 'There is a newer version of Instaclean available. Please update to continue.',
      recommended_message text DEFAULT 'A new version of Instaclean is available with improvements and fixes.',
      updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
      CONSTRAINT app_update_policy_channel_check CHECK (channel IN ('production', 'preview')),
      CONSTRAINT app_update_policy_min_version_format_check CHECK (min_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'),
      CONSTRAINT app_update_policy_recommended_version_format_check CHECK (
        recommended_version IS NULL OR recommended_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'
      )
    )
    """)

    Repo.query!("""
    INSERT INTO public.app_update_policy (channel, min_version, recommended_version)
    VALUES
      ('production', '1.5.29', NULL),
      ('preview', '1.5.29', NULL)
    """)

    :ok
  end

  test "lists production and preview policies for staff" do
    admin_id = insert_admin!()

    assert {:ok, policies} = DirectAdminAppUpdatePolicy.list(admin_id)
    assert Enum.map(policies, & &1["channel"]) == ["preview", "production"]
    assert Enum.all?(policies, &(&1["minVersion"] == "1.5.29"))
  end

  test "forbids non-staff reads and writes" do
    guest_id = insert_user!("guest@example.com", "+233500000010")

    assert {:error, :forbidden} = DirectAdminAppUpdatePolicy.list(guest_id)

    assert {:error, :forbidden} =
             DirectAdminAppUpdatePolicy.save(guest_id, %{
               "channel" => "preview",
               "minVersion" => "1.5.30",
               "requiredMessage" => "Please update."
             })
  end

  test "saves a preview policy and clears recommended when it is not above min" do
    admin_id = insert_admin!()

    assert {:ok, policy} =
             DirectAdminAppUpdatePolicy.save(admin_id, %{
               "channel" => "preview",
               "minVersion" => "1.5.31",
               "recommendedVersion" => "1.5.30",
               "requiredMessage" => "Please update to continue.",
               "recommendedMessage" => "A nicer build is ready."
             })

    assert policy["channel"] == "preview"
    assert policy["minVersion"] == "1.5.31"
    assert policy["recommendedVersion"] == nil
    assert policy["requiredMessage"] == "Please update to continue."
    assert policy["recommendedMessage"] == "A nicer build is ready."
  end

  test "keeps recommended when it is above the minimum" do
    admin_id = insert_admin!()

    assert {:ok, policy} =
             DirectAdminAppUpdatePolicy.save(admin_id, %{
               "channel" => "production",
               "minVersion" => "1.5.30",
               "recommendedVersion" => "1.5.31",
               "requiredMessage" => "Please update to continue."
             })

    assert policy["minVersion"] == "1.5.30"
    assert policy["recommendedVersion"] == "1.5.31"
  end

  test "rejects invalid marketing versions" do
    admin_id = insert_admin!()

    assert {:error, :invalid_request} =
             DirectAdminAppUpdatePolicy.save(admin_id, %{
               "channel" => "preview",
               "minVersion" => "1.5",
               "requiredMessage" => "Please update."
             })
  end

  defp insert_admin! do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233500000099")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    admin_id
  end

  defp insert_user!(email, phone) do
    id = Ecto.UUID.generate()
    uid = Ecto.UUID.dump!(id)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      uid,
      email,
      phone
    ])

    id
  end
end
