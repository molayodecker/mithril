defmodule MithrilWeb.Schemas.MobileRpc do
  @moduledoc "OpenAPI schemas for allowlisted mobile RPC results."

  defmodule PendingBookingForEdit do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PendingBookingForEdit",
      description: "One row returned by get_pending_booking_for_edit.",
      type: :object,
      properties: %{
        address: %Schema{type: :string},
        booking_cover: %Schema{type: :boolean},
        booking_cover_amount: %Schema{type: :number, nullable: true},
        booking_source: %Schema{type: :string, nullable: true},
        cleaner_assigned_at: %Schema{type: :string, format: :"date-time"},
        cleaner_id: %Schema{type: :string, format: :uuid},
        currency: %Schema{type: :string, nullable: true},
        customer_contact_phone: %Schema{type: :string},
        customer_id: %Schema{type: :string, format: :uuid},
        direct_assigned_cleaner_id: %Schema{type: :string, format: :uuid, nullable: true},
        duration_adjustment: %Schema{type: :number},
        duration_computed: %Schema{type: :number},
        duration_final: %Schema{type: :number},
        duration_hours: %Schema{type: :number},
        extra_task_ids: %Schema{type: :array, items: %Schema{type: :string}},
        final_amount_minor: %Schema{type: :integer},
        home_size: %Schema{type: :string},
        id: %Schema{type: :string, format: :uuid},
        location_latitude: %Schema{type: :number},
        location_longitude: %Schema{type: :number},
        payment_status: %Schema{type: :string},
        platform_fee: %Schema{type: :number, nullable: true},
        pricing_version: %Schema{type: :string, nullable: true},
        promotion_discount_minor: %Schema{type: :integer},
        promotion_id: %Schema{type: :string, format: :uuid, nullable: true},
        promotion_slug: %Schema{type: :string, nullable: true},
        scheduled_date: %Schema{type: :string, format: :date},
        scheduled_time: %Schema{type: :string},
        service: %Schema{type: :object, additionalProperties: true},
        service_duration_option_id: %Schema{type: :string, format: :uuid},
        service_id: %Schema{type: :integer},
        special_instructions: %Schema{type: :string},
        status: %Schema{type: :string, description: "booking_status"},
        subscription_id: %Schema{type: :string, format: :uuid},
        supplies_allowance_minor: %Schema{type: :integer},
        supplies_option: %Schema{type: :string, nullable: true},
        timezone_name: %Schema{type: :string},
        title: %Schema{type: :string},
        transportation_included: %Schema{type: :boolean},
        transportation_minor: %Schema{type: :integer},
        transportation_quote_id: %Schema{type: :string, format: :uuid, nullable: true},
        work_rate_ghs_per_hour: %Schema{type: :number, nullable: true}
      },
      required: [
        :address,
        :booking_cover,
        :cleaner_assigned_at,
        :cleaner_id,
        :customer_contact_phone,
        :customer_id,
        :duration_adjustment,
        :duration_computed,
        :duration_final,
        :duration_hours,
        :extra_task_ids,
        :final_amount_minor,
        :home_size,
        :id,
        :location_latitude,
        :location_longitude,
        :payment_status,
        :promotion_discount_minor,
        :scheduled_date,
        :scheduled_time,
        :service,
        :service_duration_option_id,
        :service_id,
        :special_instructions,
        :status,
        :subscription_id,
        :supplies_allowance_minor,
        :timezone_name,
        :title,
        :transportation_included,
        :transportation_minor
      ]
    })
  end

  defmodule PendingBookingForEditRows do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.PendingBookingForEdit

    OpenApiSpex.schema(%{
      title: "PendingBookingForEditRows",
      description: "Rows returned when mobile.rpc calls get_pending_booking_for_edit.",
      type: :array,
      items: PendingBookingForEdit
    })
  end

  defmodule RpcResult do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.PendingBookingForEditRows
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MobileRpcResult",
      type: :object,
      properties: %{
        data: %Schema{
          nullable: true,
          description:
            "Allowlisted function result. get_pending_booking_for_edit returns PendingBookingForEdit rows.",
          oneOf: [
            PendingBookingForEditRows,
            %Schema{type: :object, additionalProperties: true},
            %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
            %Schema{type: :string},
            %Schema{type: :number},
            %Schema{type: :boolean}
          ]
        }
      },
      required: [:data]
    })
  end
end
