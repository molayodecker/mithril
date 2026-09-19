defmodule Mithril.DirectAdminOpsDesksTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminNotifications
  alias Mithril.DirectAdminWhatsApp
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate ops desk fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["whatsapp_inbox_messages", "notifications", "profiles", "user_roles", "users"] do
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
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.notifications (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid,
      title text NOT NULL,
      message text NOT NULL,
      type text NOT NULL,
      read boolean DEFAULT false,
      data jsonb DEFAULT '{}'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.whatsapp_inbox_messages (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      direction text NOT NULL,
      phone_e164 text NOT NULL,
      body text NOT NULL,
      user_id uuid,
      sent_by_user_id uuid,
      business_phone_e164 text,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    :ok
  end

  test "sends an in-app notification and lists it" do
    admin_id = insert_admin!()
    target_id = insert_user!("guest@example.com", "+233500000010", "Ama Guest")

    assert {:ok, sent} =
             DirectAdminNotifications.send(admin_id, %{
               "targetUserId" => target_id,
               "title" => "Visit update",
               "message" => "Your cleaner is on the way."
             })

    assert sent["ok"] == true
    assert sent["inboxCreated"] == true

    assert {:ok, page} = DirectAdminNotifications.list_deliveries(admin_id)
    assert [%{"title" => "Visit update", "recipientName" => "Ama Guest"}] = page["deliveries"]
    assert page["total"] == 1
    assert page["page"] == 1
    assert page["limit"] == 25
    assert page["totalPages"] == 1
  end

  test "paginates notification deliveries" do
    admin_id = insert_admin!()
    target_id = insert_user!("guest@example.com", "+233500000012", "Ama Guest")
    uid = Ecto.UUID.dump!(target_id)

    for {title, offset} <- [{"First", 2}, {"Second", 1}, {"Third", 0}] do
      Repo.query!(
        """
        INSERT INTO public.notifications (user_id, title, message, type, read, created_at)
        VALUES ($1, $2, 'Body', 'admin_message', false, now() - ($3::int * interval '1 minute'))
        """,
        [uid, title, offset]
      )
    end

    assert {:ok, first} =
             DirectAdminNotifications.list_deliveries(admin_id, %{"page" => 1, "limit" => 2})

    assert Enum.map(first["deliveries"], & &1["title"]) == ["Third", "Second"]
    assert first["total"] == 3
    assert first["totalPages"] == 2

    assert {:ok, second} =
             DirectAdminNotifications.list_deliveries(admin_id, %{"page" => 2, "limit" => 2})

    assert Enum.map(second["deliveries"], & &1["title"]) == ["First"]
  end

  test "previews a customer broadcast audience" do
    admin_id = insert_admin!()
    customer_id = insert_user!("guest@example.com", "+233500000013", "Ama Guest")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'customer')", [
      Ecto.UUID.dump!(customer_id)
    ])

    assert {:ok, preview} =
             DirectAdminNotifications.preview_broadcast(admin_id, %{"segment" => "customers"})

    assert preview["segmentTotalCount"] == 1
    assert preview["selectedForRun"] == 1
    assert preview["withPhoneCount"] == 1
    assert preview["capped"] == false
  end

  test "lists WhatsApp threads and messages" do
    admin_id = insert_admin!()
    guest_id = insert_user!("guest@example.com", "+233500000011", "Kofi Guest")

    Repo.query!(
      """
      INSERT INTO public.whatsapp_inbox_messages (direction, phone_e164, body, user_id)
      VALUES ('inbound', '+233500000011', 'Hello ops', $1)
      """,
      [Ecto.UUID.dump!(guest_id)]
    )

    assert {:ok, [thread]} = DirectAdminWhatsApp.list_threads(admin_id)
    assert thread["phoneE164"] == "+233500000011"
    assert thread["displayLabel"] == "Kofi Guest"

    assert {:ok, [message]} = DirectAdminWhatsApp.list_messages(admin_id, "+233500000011")
    assert message["body"] == "Hello ops"
    assert message["direction"] == "inbound"
  end

  defp insert_admin! do
    admin_id = insert_user!("ops@tryinstaclean.com", "+233500000099", "Ops")

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    admin_id
  end

  defp insert_user!(email, phone, name) do
    id = Ecto.UUID.generate()
    uid = Ecto.UUID.dump!(id)

    Repo.query!("INSERT INTO public.users (id, email, phone) VALUES ($1, $2, $3)", [
      uid,
      email,
      phone
    ])

    Repo.query!("INSERT INTO public.profiles (id, fullname) VALUES ($1, $2)", [uid, name])
    id
  end
end
