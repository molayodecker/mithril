defmodule MithrilWeb.DirectMarketingQuotesController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.MarketingQuotes

  def create(conn, params) do
    case MarketingQuotes.submit(params) do
      {:ok, :accepted} ->
        json(conn, %{ok: true})

      {:error, :invalid} ->
        conn |> put_status(422) |> json(%{ok: false, error: "invalid_quote"})

      {:error, :email_failed} ->
        conn |> put_status(502) |> json(%{ok: false, error: "email_failed"})

      {:error, :whatsapp_failed} ->
        conn |> put_status(502) |> json(%{ok: false, error: "whatsapp_failed"})
    end
  end
end
