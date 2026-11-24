defmodule Mithril.DirectAdminWhatsAppCustomerTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminWhatsApp
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "refuses a caller who is not staff" do
    assert {:error, :forbidden} =
             DirectAdminWhatsApp.create_customer(Ecto.UUID.generate(), %{
               "phoneE164" => "+233541118319",
               "name" => "Ama Mensah"
             })
  end

  test "rejects a blank name before checking staff access" do
    assert {:error, :invalid_request} =
             DirectAdminWhatsApp.create_customer(Ecto.UUID.generate(), %{
               "phoneE164" => "+233541118319",
               "name" => "   "
             })
  end

  test "rejects a phone that is not a number before checking staff access" do
    assert {:error, :invalid_phone} =
             DirectAdminWhatsApp.create_customer(Ecto.UUID.generate(), %{
               "phoneE164" => "not-a-phone",
               "name" => "Ama Mensah"
             })
  end
end
