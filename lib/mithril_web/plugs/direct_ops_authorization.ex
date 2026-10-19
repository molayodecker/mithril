defmodule MithrilWeb.Plugs.DirectOpsAuthorization do
  @moduledoc """
  Enforces assigned Direct operations desk grants on the server.

  Legacy reviewers with no desk grants retain their existing access; once any
  desk grant is present, access is restricted to matching operations.
  """
  import Plug.Conn

  alias Mithril.Auth
  alias Mithril.Repo

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["direct", "admin" | rest]} = conn, _opts) do
    user_id = conn.assigns[:instaclean_user_id]

    cond do
      not is_binary(user_id) -> reject(conn)
      Auth.admin?(user_id) -> conn
      true -> authorize_scoped(conn, user_id, rest)
    end
  end

  def call(conn, _opts), do: conn

  defp authorize_scoped(conn, user_id, rest) do
    case Repo.query(
           "SELECT role_id::text FROM public.user_roles WHERE user_id = $1::uuid AND (role_id = 'reviewer' OR role_id = ANY($2::text[]))",
           [Ecto.UUID.dump!(user_id), Mithril.OpsPermissions.ids()]
         ) do
      {:ok, %{rows: rows}} ->
        roles = Enum.map(rows, &hd/1)
        permissions = Enum.filter(roles, &Mithril.OpsPermissions.valid?/1)

        cond do
          permissions == [] and "reviewer" in roles -> conn
          "reviewer" in roles and permission_for(rest, conn.method) == "billing" -> conn
          permission_for(rest, conn.method) in permissions -> conn
          true -> reject(conn)
        end

      {:error, _} ->
        reject(conn)
    end
  end

  # Administrative role changes and financial transfers are admin-only.
  defp permission_for(["team" | _], _), do: nil
  defp permission_for(["accounts", "merge"], _), do: nil
  defp permission_for(["payouts" | _], _), do: nil
  defp permission_for(["cleaners", _, "wallet-credit"], _), do: nil
  defp permission_for(["cleaners", _, "wallet"], _), do: nil
  defp permission_for(["bookings", _, "cash-payout"], _), do: nil
  defp permission_for(["bookings", _, "invoice" | _], _), do: "billing"
  defp permission_for(["billing" | _], _), do: "billing"
  defp permission_for(["worker-loan-requests" | _], _), do: "finance_loans"
  defp permission_for(["notification-" <> _ | _], _), do: "notifications"
  defp permission_for(["notifications" | _], _), do: "notifications"
  defp permission_for(["whatsapp" | _], _), do: "whatsapp_inbox"
  defp permission_for(["dispatch-map" | _], _), do: "dispatch_map"
  defp permission_for(["service-requests" | _], _), do: "dispatch"
  defp permission_for(["live-jobs" | _], _), do: "live"
  defp permission_for(["bookings" | _], _), do: "bookings"
  defp permission_for(["customers" | _], _), do: "users"
  defp permission_for(["placements" | _], _), do: "placements"
  defp permission_for(["candidates" | _], _), do: "placements"
  defp permission_for(["cleaner-applications" | _], _), do: "cleaner_applications"
  defp permission_for(["cleaner-application-drafts" | _], _), do: "cleaner_applications"
  defp permission_for(["cleaner-health" | _], _), do: "cleaner_health"
  defp permission_for(["cleaner-verifications" | _], _), do: "cleaner_verifications"
  defp permission_for(["cleaners" | _], _), do: "cleaners_roster"
  defp permission_for(["customer-trust" | _], _), do: "customer_trust"
  defp permission_for(["services" | _], _), do: "services"
  defp permission_for(["promotion-codes" | _], _), do: "services"
  defp permission_for(["reports" | _], _), do: "reports"
  defp permission_for(["app-update-policy" | _], _), do: "settings"
  defp permission_for(_, _), do: nil

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    |> halt()
  end
end
