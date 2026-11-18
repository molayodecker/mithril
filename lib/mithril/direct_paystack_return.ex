defmodule Mithril.DirectPaystackReturn do
  @moduledoc """
  Paystack hosted-checkout browser return at `GET /bookings/:id`.
  Returns HTML that deep-links into the native app (`{scheme}://booking-status?…`).
  """

  @default_scheme "instaclean"
  @allowed_schemes MapSet.new(["instaclean", "instaclean-preview"])

  @spec valid_booking_id?(String.t()) :: boolean()
  def valid_booking_id?(id) when is_binary(id) do
    case Ecto.UUID.cast(String.trim(id)) do
      {:ok, _} -> true
      :error -> false
    end
  end

  def valid_booking_id?(_), do: false

  @spec normalize_scheme(term()) :: String.t()
  def normalize_scheme(nil), do: @default_scheme

  def normalize_scheme(scheme) when is_binary(scheme) do
    scheme
    |> String.trim()
    |> String.trim_trailing(":")
    |> String.trim_trailing("/")
    |> case do
      "" ->
        @default_scheme

      normalized ->
        if MapSet.member?(@allowed_schemes, normalized), do: normalized, else: @default_scheme
    end
  end

  def normalize_scheme(_), do: @default_scheme

  @spec build_deep_link(String.t(), keyword()) :: String.t()
  def build_deep_link(booking_id, opts \\ []) when is_binary(booking_id) do
    scheme = opts |> Keyword.get(:scheme) |> normalize_scheme()
    reference = reference_from_opt(Keyword.get(opts, :reference))

    query =
      [{"bookingId", String.trim(booking_id)}, {"source", "payment"}]
      |> append_reference(reference)
      |> URI.encode_query()

    "#{scheme}://booking-status?#{query}"
  end

  @spec resolve_from_query(String.t(), map()) :: String.t()
  def resolve_from_query(booking_id, query_params)
      when is_binary(booking_id) and is_map(query_params) do
    if cancel_outcome?(query_params) do
      build_cancel_deep_link(booking_id, scheme: query_params["scheme"])
    else
      reference =
        query_params["reference"] ||
          query_params["trxref"]

      build_deep_link(booking_id,
        scheme: query_params["scheme"],
        reference: reference
      )
    end
  end

  @doc """
  Paystack only leaves the hosted checkout when `metadata.cancel_action` is an
  HTTPS URL. Reuse the validated callback and mark it as a cancel return.
  """
  @spec cancel_action_url(String.t()) :: String.t()
  def cancel_action_url(callback_url) when is_binary(callback_url) do
    uri = URI.parse(callback_url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("outcome", "cancel")

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  @spec build_cancel_deep_link(String.t(), keyword()) :: String.t()
  def build_cancel_deep_link(booking_id, opts \\ []) when is_binary(booking_id) do
    scheme = opts |> Keyword.get(:scheme) |> normalize_scheme()
    query = URI.encode_query([{"booking_id", String.trim(booking_id)}])
    "#{scheme}://payment/cancel?#{query}"
  end

  @spec redirect_html(String.t()) :: String.t()
  def redirect_html(deep_link) when is_binary(deep_link) do
    escaped_attr =
      deep_link
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")

    script_target = Jason.encode!(deep_link)

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta http-equiv="refresh" content="0;url=#{escaped_attr}" />
        <title>#{page_title(deep_link)}</title>
        <style>
          body { font-family: system-ui, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background: #f8fafc; color: #0f172a; }
          main { text-align: center; padding: 2rem; }
        </style>
      </head>
      <body>
        <main>
          <p>Returning to Instaclean…</p>
          <p><a href="#{escaped_attr}">Open the app</a></p>
        </main>
        <script>window.location.replace(#{script_target});</script>
      </body>
    </html>
    """
  end

  defp page_title(deep_link) do
    if String.contains?(deep_link, "://payment/cancel?") do
      "Payment cancelled — Instaclean"
    else
      "Payment complete — Instaclean"
    end
  end

  defp cancel_outcome?(%{"outcome" => "cancel"}), do: true
  defp cancel_outcome?(_), do: false

  defp reference_from_opt(ref) when is_binary(ref) do
    trimmed = String.trim(ref)
    if trimmed == "", do: nil, else: trimmed
  end

  defp reference_from_opt(_), do: nil

  defp append_reference(params, nil), do: params
  defp append_reference(params, reference), do: params ++ [{"reference", reference}]
end
