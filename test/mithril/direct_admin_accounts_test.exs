defmodule Mithril.DirectAdminAccountsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminAccounts
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "forbids non-admin callers" do
    guest_id = Ecto.UUID.generate()
    primary = Ecto.UUID.generate()
    secondary = Ecto.UUID.generate()

    assert {:error, :forbidden} = DirectAdminAccounts.merge(guest_id, %{})

    assert {:error, :forbidden} =
             DirectAdminAccounts.merge(guest_id, %{
               "primaryUserId" => primary,
               "secondaryUserId" => secondary
             })
  end
end
