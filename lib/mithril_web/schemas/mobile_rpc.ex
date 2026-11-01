defmodule MithrilWeb.Schemas.MobileRpc do
  @moduledoc "OpenAPI schemas for allowlisted mobile RPC results."

  defmodule PendingBookingService do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PendingBookingService",
      description:
        "service_types row embedded by get_pending_booking_for_edit via to_jsonb(s.*).",
      type: :object,
      additionalProperties: false,
      properties: %{
        id: %Schema{type: :integer},
        category_id: %Schema{type: :integer, nullable: true},
        name: %Schema{type: :string},
        price: %Schema{type: :number},
        duration: %Schema{type: :string},
        category: %Schema{
          type: :string,
          enum:
            ~w(cleaning washing ironing flooding airbnb quick_tasks caregiving pet_care cooks drivers)
        },
        discount: %Schema{type: :number, nullable: true},
        active: %Schema{type: :boolean, nullable: true},
        image_url: %Schema{type: :string, nullable: true},
        features: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        last_updated: %Schema{type: :string, format: :"date-time", nullable: true},
        specialty_slug: %Schema{type: :string, nullable: true},
        minimum_duration_hours: %Schema{type: :number},
        maximum_duration_hours: %Schema{type: :number},
        duration_increment_hours: %Schema{type: :number},
        description: %Schema{type: :string, nullable: true},
        icon_scale: %Schema{type: :number},
        weight: %Schema{type: :integer}
      },
      required: [
        :id,
        :name,
        :price,
        :duration,
        :category,
        :minimum_duration_hours,
        :maximum_duration_hours,
        :duration_increment_hours,
        :icon_scale,
        :weight
      ]
    })
  end

  defmodule PendingBookingForEdit do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.PendingBookingService
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
        service: PendingBookingService,
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

  defmodule BookingPaymentSnapshot do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "BookingPaymentSnapshot",
      description: "One row returned by get_booking_payment_snapshot.",
      type: :object,
      additionalProperties: false,
      properties: %{
        booking_id: %Schema{type: :string, format: :uuid},
        final_amount_minor: %Schema{type: :integer},
        currency: %Schema{type: :string},
        payment_status: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, description: "booking_status"},
        booking_cover: %Schema{type: :boolean},
        booking_cover_amount: %Schema{type: :number, nullable: true},
        platform_fee: %Schema{type: :number, nullable: true},
        work_rate_ghs_per_hour: %Schema{type: :number, nullable: true},
        pricing_version: %Schema{type: :string, nullable: true},
        promotion_id: %Schema{type: :string, format: :uuid, nullable: true},
        promotion_slug: %Schema{type: :string, nullable: true},
        promotion_discount_minor: %Schema{type: :integer},
        subscription_recurring_amount_minor: %Schema{type: :integer, nullable: true},
        cleaner_earnings_minor: %Schema{type: :integer, nullable: true}
      },
      required: [
        :booking_id,
        :final_amount_minor,
        :currency,
        :status,
        :booking_cover,
        :promotion_discount_minor
      ]
    })
  end

  defmodule BookingPaymentSnapshotRows do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.BookingPaymentSnapshot

    OpenApiSpex.schema(%{
      title: "BookingPaymentSnapshotRows",
      description: "Rows returned when mobile.rpc calls get_booking_payment_snapshot.",
      type: :array,
      items: BookingPaymentSnapshot
    })
  end

  defmodule AssignedCleanerForCustomerBooking do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AssignedCleanerForCustomerBooking",
      description: "One row returned by get_assigned_cleaner_for_customer_booking.",
      type: :object,
      additionalProperties: false,
      properties: %{
        cleaner_id: %Schema{type: :string, format: :uuid},
        fullname: %Schema{type: :string, nullable: true},
        firstname: %Schema{type: :string, nullable: true},
        lastname: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        rating: %Schema{type: :number, nullable: true},
        completed_jobs: %Schema{type: :integer, nullable: true},
        hourly_rate: %Schema{type: :number, nullable: true},
        verified: %Schema{type: :boolean, nullable: true},
        specialties: %Schema{type: :array, items: %Schema{type: :string}, nullable: true}
      },
      required: [:cleaner_id]
    })
  end

  defmodule AssignedCleanerForCustomerBookingRows do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.AssignedCleanerForCustomerBooking

    OpenApiSpex.schema(%{
      title: "AssignedCleanerForCustomerBookingRows",
      description:
        "Rows returned when mobile.rpc calls get_assigned_cleaner_for_customer_booking.",
      type: :array,
      items: AssignedCleanerForCustomerBooking
    })
  end

  defmodule RpcResult do
    require OpenApiSpex
    alias MithrilWeb.Schemas.MobileRpc.AssignedCleanerForCustomerBookingRows
    alias MithrilWeb.Schemas.MobileRpc.BookingPaymentSnapshotRows
    alias MithrilWeb.Schemas.MobileRpc.PendingBookingForEditRows
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MobileRpcResult",
      type: :object,
      properties: %{
        data: %Schema{
          nullable: true,
          description:
            "Allowlisted function result. get_pending_booking_for_edit returns PendingBookingForEdit rows. get_booking_payment_snapshot returns BookingPaymentSnapshot rows. get_assigned_cleaner_for_customer_booking returns AssignedCleanerForCustomerBooking rows. Other allowlisted functions still return a JSON value.",
          oneOf: [
            PendingBookingForEditRows,
            BookingPaymentSnapshotRows,
            AssignedCleanerForCustomerBookingRows,
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
