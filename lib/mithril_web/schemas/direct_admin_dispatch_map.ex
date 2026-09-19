defmodule MithrilWeb.Schemas.DirectAdminDispatchMap do
  @moduledoc "OpenAPI schemas for the Direct admin dispatch map."

  defmodule Cleaner do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminDispatchMapCleaner",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        displayName: %Schema{type: :string},
        latitude: %Schema{type: :number, nullable: true},
        longitude: %Schema{type: :number, nullable: true},
        maxTravelDistanceMeters: %Schema{type: :integer},
        specialties: %Schema{type: :array, items: %Schema{type: :string}},
        serviceAreas: %Schema{type: :array, items: %Schema{type: :string}},
        rating: %Schema{type: :number, nullable: true},
        completedJobs: %Schema{type: :number, nullable: true},
        verified: %Schema{type: :boolean},
        status: %Schema{type: :string}
      },
      required: [
        :userId,
        :displayName,
        :maxTravelDistanceMeters,
        :specialties,
        :serviceAreas,
        :verified,
        :status
      ]
    })
  end

  defmodule CustomerBooking do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminDispatchMapBooking",
      type: :object,
      properties: %{
        bookingId: %Schema{type: :string, format: :uuid},
        customerId: %Schema{type: :string, format: :uuid},
        customerName: %Schema{type: :string},
        address: %Schema{type: :string},
        latitude: %Schema{type: :number},
        longitude: %Schema{type: :number},
        scheduledAtUtc: %Schema{type: :string, format: :"date-time", nullable: true},
        timezoneName: %Schema{type: :string},
        status: %Schema{type: :string},
        serviceName: %Schema{type: :string},
        cleanerId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [
        :bookingId,
        :customerId,
        :customerName,
        :address,
        :latitude,
        :longitude,
        :timezoneName,
        :status,
        :serviceName
      ]
    })
  end

  defmodule MapResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminDispatchMap.{Cleaner, CustomerBooking}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminDispatchMapResponse",
      type: :object,
      properties: %{
        cleaners: %Schema{type: :array, items: Cleaner},
        customerBookings: %Schema{type: :array, items: CustomerBooking}
      },
      required: [:cleaners, :customerBookings]
    })
  end
end
