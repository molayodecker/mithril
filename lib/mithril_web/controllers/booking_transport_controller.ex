defmodule MithrilWeb.BookingTransportController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.Transport.Estimate
  alias OpenApiSpex.Schema

  tags(["bookings"])

  operation(:estimate,
    operation_id: "bookings.transportEstimate",
    summary: "Instaclean transport estimate for an owned booking",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {"Transport estimate", "application/json", %Schema{type: :object}}
    ]
  )

  def estimate(conn, %{"id" => booking_id}) do
    respond(conn, Estimate.for_booking(conn.assigns.instaclean_user_id, booking_id))
  end

  defp respond(conn, {:ok, data}), do: json(conn, %{data: data})

  defp respond(conn, {:error, {:status, status, body}}) when is_map(body) do
    conn |> put_status(status) |> json(body)
  end

  defp respond(conn, {:error, :forbidden}) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  defp respond(conn, {:error, _}) do
    conn |> put_status(400) |> json(%{error: "bad_request"})
  end
end
