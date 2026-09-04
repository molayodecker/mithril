defmodule MithrilWeb.Plugs.ParityAuth do
  @moduledoc """
  Protects temporary migration-parity endpoints.

  These routes are not customer-facing APIs. They are available only when a
  server-side parity token is configured at boot and the caller supplies the
  same value in `x-mithril-parity-token`.
  """

  import Plug.Conn

  @header "x-mithril-parity-token"

  def init(opts), do: opts

  def call(conn, _opts) do
    configured = Application.get_env(:mithril, :parity_token)
    supplied = conn |> get_req_header(@header) |> List.first()

    if valid_token?(configured, supplied) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  defp valid_token?(configured, supplied)
       when is_binary(configured) and is_binary(supplied) and byte_size(configured) > 0 and
              byte_size(configured) == byte_size(supplied) do
    Plug.Crypto.secure_compare(configured, supplied)
  end

  defp valid_token?(_, _), do: false
end
