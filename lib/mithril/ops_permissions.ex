defmodule Mithril.OpsPermissions do
  @moduledoc """
  Direct ops desk permission slugs stored in `user_roles.role_id`.

  Admins bypass per-desk checks. Reviewers retain broad legacy access until
  permissions are assigned explicitly.
  """

  @catalog [
    %{id: "overview", label: "Admin overview"},
    %{id: "users", label: "Users"},
    %{id: "bookings", label: "Bookings"},
    %{id: "dispatch", label: "Concierge & dispatch"},
    %{id: "dispatch_map", label: "Dispatch map"},
    %{id: "live", label: "Live jobs"},
    %{id: "whatsapp_inbox", label: "Customer messages: WhatsApp, SMS, and email (send)"},
    %{id: "notifications", label: "Notifications"},
    %{id: "placements", label: "Placements"},
    %{id: "cleaners_roster", label: "Cleaners (roster & profiles)"},
    %{id: "cleaner_applications", label: "Cleaner applications (approve / reject)"},
    %{id: "cleaner_verifications", label: "Ghana Card / verifications"},
    %{id: "customer_trust", label: "Customer trust review"},
    %{id: "cleaner_health", label: "Worker health"},
    %{id: "services", label: "Services & discounts"},
    %{id: "extra_tasks", label: "Extra tasks"},
    %{id: "platform_fees", label: "Platform fees"},
    %{id: "billing", label: "Billing & invoices"},
    %{id: "finance_loans", label: "Worker finance & loans"},
    %{id: "analytics", label: "Analytics"},
    %{id: "reports", label: "Reports"},
    %{id: "system_health", label: "System health"},
    %{id: "settings", label: "Settings & policy"}
  ]

  @ids Enum.map(@catalog, & &1.id)

  def catalog, do: @catalog

  def ids, do: @ids

  def id_set, do: MapSet.new(@ids)

  def valid?(id) when is_binary(id), do: id in @ids
  def valid?(_), do: false

  def split_roles(role_ids) when is_list(role_ids) do
    staff = Enum.filter(role_ids, &(&1 in ~w(admin reviewer)))
    permissions = Enum.filter(role_ids, &valid?/1)
    {staff, permissions}
  end

  def split_roles(_), do: {[], []}
end
