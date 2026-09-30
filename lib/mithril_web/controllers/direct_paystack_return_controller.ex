defmodule MithrilWeb.DirectPaystackReturnController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias Mithril.DirectPaystackReturn

  def show(conn, %{"id" => id}) do
    if DirectPaystackReturn.valid_booking_id?(id) do
      deep_link = DirectPaystackReturn.resolve_from_query(id, conn.query_params)
      html = DirectPaystackReturn.redirect_html(deep_link)

      conn
      |> put_resp_content_type("text/html; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, html)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "Invalid booking ID"}))
    end
  end
end
