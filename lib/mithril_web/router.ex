defmodule MithrilWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: MithrilWeb.ApiSpec
  end

  pipeline :parity do
    plug MithrilWeb.Plugs.ParityAuth
  end

  pipeline :direct_gateway do
    plug MithrilWeb.Plugs.DirectGatewayAuth
  end

  pipeline :user_auth do
    plug MithrilWeb.Plugs.UserAuth
  end

  pipeline :whatsapp do
    plug :accepts, ["html", "xml", "json"]
  end

  scope "/", MithrilWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/ready", ReadyController, :show
  end

  scope "/", MithrilWeb do
    pipe_through :whatsapp

    get "/whatsapp/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve
    post "/whatsapp/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve
    options "/whatsapp/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve

    get "/functions/v1/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve
    post "/functions/v1/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve
    options "/functions/v1/join-as-cleaner-bot", WhatsAppRecruitmentController, :serve
  end

  scope "/" do
    pipe_through :api

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/auth", MithrilWeb do
    pipe_through :api

    get "/methods", AuthController, :methods
    post "/login", AuthController, :login
    post "/otp", AuthController, :request_otp
    post "/otp/verify", AuthController, :verify_otp
    post "/oauth/:provider", AuthController, :oauth
    post "/refresh", AuthController, :refresh
    post "/logout", AuthController, :logout
    post "/register", AuthController, :register
  end

  scope "/auth", MithrilWeb do
    pipe_through [:api, :user_auth]

    get "/me", AuthController, :me
    post "/password", AuthController, :set_password
  end

  scope "/internal/parity", MithrilWeb do
    pipe_through [:api, :parity]

    get "/bookings/:id", ParityBookingController, :show
  end

  scope "/direct", MithrilWeb do
    pipe_through [:api, :direct_gateway]

    get "/booking-services", DirectBookingController, :list_services
    get "/booking-cleaners", DirectBookingController, :list_cleaners
    post "/booking-price", DirectBookingController, :preview_price
    post "/bookings", DirectBookingController, :create
    get "/bookings", DirectBookingController, :index
    get "/bookings/:id", DirectBookingController, :show
    get "/bookings/:id/cancellation-policy", DirectOperationsController, :cancellation_policy
    post "/bookings/:id/refund-request", DirectOperationsController, :request_refund
    post "/bookings/:id/cancel", DirectBookingController, :cancel
    post "/bookings/:id/reschedule", DirectBookingController, :reschedule
    post "/bookings/:id/payment", DirectBookingController, :initialize_payment
    post "/bookings/:id/payment/verify", DirectBookingController, :verify_payment
    post "/bookings/:id/replacement-request", DirectDispatchController, :request_replacement

    get "/service-requests", DirectDispatchController, :list_service_requests
    post "/urgent-help", DirectDispatchController, :create_urgent_request

    get "/placements", DirectController, :list_placements
    post "/placements", DirectController, :create_placement
    get "/placements/:id", DirectController, :show_placement

    get "/helpers", DirectController, :list_helpers
    post "/helpers", DirectController, :create_helper

    post "/matches/:id/hire", DirectController, :hire_match

    get "/admin/placements", DirectController, :list_admin_placements
    get "/admin/candidates", DirectController, :list_admin_candidates
    get "/admin/cleaner-applications", DirectController, :list_admin_cleaner_applications
    get "/admin/cleaner-applications/:id", DirectController, :show_admin_cleaner_application

    post "/admin/cleaner-applications/:id/approve",
         DirectOperationsController,
         :approve_cleaner_application

    get "/admin/cleaner-application-drafts",
        DirectController,
        :list_admin_cleaner_application_drafts

    get "/admin/cleaner-application-drafts/:id",
        DirectController,
        :show_admin_cleaner_application_draft

    get "/admin/cleaner-health", DirectController, :list_admin_cleaner_health
    get "/admin/cleaner-health/:id", DirectController, :show_admin_cleaner_health_case

    post "/admin/cleaner-health/:id/actions",
         DirectController,
         :record_admin_cleaner_health_action

    get "/admin/customer-trust", DirectController, :list_admin_customer_trust
    get "/admin/customer-trust/:id", DirectController, :show_admin_customer_trust
    post "/admin/customer-trust/:id/notes", DirectController, :add_admin_customer_trust_note

    post "/admin/customer-trust/:id/actions",
         DirectController,
         :record_admin_customer_trust_action

    post "/admin/placements/:id/matches", DirectController, :match_admin_candidate

    get "/admin/customers", DirectDispatchController, :list_admin_customers
    get "/admin/app-update-policy", DirectAdminAppUpdatePolicyController, :index
    post "/admin/app-update-policy", DirectAdminAppUpdatePolicyController, :save
    get "/admin/notifications", DirectAdminNotificationsController, :index
    get "/admin/notification-targets", DirectAdminNotificationsController, :search

    get "/admin/notification-broadcast/preview",
        DirectAdminNotificationsController,
        :preview_broadcast

    post "/admin/notification-broadcast", DirectAdminNotificationsController, :broadcast
    post "/admin/notifications", DirectAdminNotificationsController, :create
    get "/admin/whatsapp/threads", DirectAdminWhatsAppController, :index
    get "/admin/whatsapp/messages", DirectAdminWhatsAppController, :messages
    post "/admin/whatsapp/send", DirectAdminWhatsAppController, :send
    post "/admin/whatsapp/sms", DirectAdminWhatsAppController, :sms
    get "/admin/dispatch-map", DirectAdminDispatchMapController, :show
    get "/admin/bookings", DirectAdminBookingsController, :index
    get "/admin/cleaners", DirectOperationsController, :list_admin_cleaners

    get "/admin/bookings/:id/payment-diagnostics",
        DirectOperationsController,
        :payment_diagnostics

    get "/admin/bookings/:id", DirectAdminBookingsController, :show
    post "/admin/bookings", DirectDispatchController, :create_admin_booking
    post "/admin/bookings/:id/assign", DirectAdminBookingsController, :assign
    post "/admin/bookings/:id/status", DirectAdminBookingsController, :update_status
    post "/admin/bookings/:id/cancel", DirectAdminBookingsController, :cancel
    post "/admin/bookings/:id/reschedule", DirectAdminBookingsController, :reschedule
    post "/admin/bookings/:id/reset-hold", DirectAdminBookingsController, :reset_hold
    post "/admin/bookings/:id/cash-payout", DirectAdminBookingsController, :cash_payout
    post "/admin/bookings/:id/notify-cleaner", DirectAdminBookingsController, :notify_cleaner
    post "/admin/bookings/:id/send-receipt", DirectAdminBookingsController, :send_receipt
    get "/admin/service-requests", DirectDispatchController, :list_admin_service_requests

    post "/admin/service-requests/:id/assign",
         DirectDispatchController,
         :assign_admin_service_request

    post "/admin/service-requests/:id/status",
         DirectDispatchController,
         :update_admin_service_request
  end
end
