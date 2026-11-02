defmodule MithrilWeb.Schemas.VoiceBookingCall do
  @moduledoc """
  The arm response contains only the public Twilio number. The other party's
  phone is resolved on the server when Twilio requests call instructions.
  """

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "VoiceBookingCallRequest",
      type: :object,
      properties: %{
        bookingId: %Schema{type: :string, format: :uuid},
        contactRole: %Schema{type: :string, enum: ["customer", "site"], nullable: true}
      },
      required: [:bookingId]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "VoiceBookingCallResponse",
      type: :object,
      properties: %{
        dialNumber: %Schema{type: :string, example: "+233200000099"}
      },
      required: [:dialNumber]
    })
  end

  defmodule Error do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "VoiceBookingCallError",
      type: :object,
      properties: %{
        error: %Schema{type: :string}
      },
      required: [:error]
    })
  end
end
