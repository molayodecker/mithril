defmodule MithrilWeb.Plugs.GuestMobileRateLimit do
  @moduledoc false

  import Plug.Conn

  alias Mithril.GuestMobileRateLimit

  def init(opts), do: opts

  def call(conn, _opts) do
    case rate_limit(conn) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        body = Jason.encode!(%{error: "guest_rate_limited"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, body)
        |> halt()
    end
  end

  defp rate_limit(conn) do
    client_ip = request_ip(conn)

    case guest_route_kind(conn) do
      :timezone -> GuestMobileRateLimit.check_guest_timezone(client_ip)
      :guest_prep -> GuestMobileRateLimit.check_guest_prep(client_ip)
    end
  end

  defp guest_route_kind(conn) do
    if conn.request_path == "/mobile/guest/actions/timezone" or
         normalize_route_name(conn.path_params["name"]) == "timezone",
       do: :timezone,
       else: :guest_prep
  end

  defp normalize_route_name(name) when is_binary(name), do: name

  defp normalize_route_name(name) when is_list(name), do: Enum.join(name, "/")

  defp normalize_route_name(_), do: ""

  defp request_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" -> String.trim(ip)
      _ -> remote_ip(conn.remote_ip)
    end
  end

  defp remote_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end

  defp remote_ip(_), do: nil
end
