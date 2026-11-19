defmodule MithrilWeb.DirectMarketingQuotesController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.MarketingQuotes
  alias Mithril.RateLimiter

  @max_submissions_per_minute 5

  def create(conn, params) do
    # Throttle unauthenticated submissions by the connection's peer address,
    # rather than user-supplied headers or form fields.
    key = {:marketing_quote, conn.remote_ip}

    case RateLimiter.check(key, @max_submissions_per_minute, 60_000) do
      :ok ->
        submit_quote(conn, params)

      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{ok: false, error: "rate_limited"})
    end
  end

  defp submit_quote(conn, params) do
    case MarketingQuotes.submit(params) do
      {:ok, :accepted} ->
        json(conn, %{ok: true})

      {:error, :invalid} ->
        conn |> put_status(422) |> json(%{ok: false, error: "invalid_quote"})

      {:error, :email_failed} ->
        conn |> put_status(502) |> json(%{ok: false, error: "email_failed"})

    end
  end
end
