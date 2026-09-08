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

  scope "/", MithrilWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/ready", ReadyController, :show
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
    get "/bookings/:id", DirectBookingController, :show
    get "/bookings/:id/cancellation-policy", DirectOperationsController, :cancellation_policy
    post "/bookings/:id/cancel", DirectOperationsController, :cancel_booking
    post "/bookings/:id/refund-request", DirectOperationsController, :request_refund
    post "/bookings/:id/reschedule", DirectOperationsController, :reschedule_booking
    post "/bookings/:id/payment", DirectBookingController, :initialize_payment
    post "/bookings/:id/payment/verify", DirectBookingController, :verify_payment
    post "/bookings/:id/replacement-request", DirectDispatchController, :request_replacement

    get "/service-requests", DirectDispatchController, :list_service_requests
    post "/urgent-help", DirectDispatchController, :create_urgent_request

    get "/placements", DirectController, :list_placements
    post "/placements", DirectController, :create_placement
    get "/placements/:id", DirectController, :show_placement

    get "/placements/:placement_id/candidates/:candidate_id/video",
        DirectVideoController,
        :show_candidate_video

    get "/helpers", DirectController, :list_helpers
    post "/helpers", DirectController, :create_helper

    post "/matches/:id/hire", DirectController, :hire_match

    get "/admin/placements", DirectController, :list_admin_placements
    get "/admin/candidates", DirectController, :list_admin_candidates
    get "/admin/candidates/:candidate_id/video", DirectVideoController, :show_admin_candidate_video
    put "/admin/candidates/:candidate_id/video", DirectVideoController, :update_admin_candidate_video
    post "/admin/placements/:id/matches", DirectController, :match_admin_candidate

    get "/admin/customers", DirectDispatchController, :list_admin_customers
    post "/admin/bookings", DirectDispatchController, :create_admin_booking
    get "/admin/service-requests", DirectDispatchController, :list_admin_service_requests
    get "/admin/cleaners", DirectOperationsController, :list_admin_cleaners

    get "/admin/cleaner-applications",
        DirectOperationsController,
        :list_admin_cleaner_applications

    post "/admin/cleaner-applications/:id/approve",
         DirectOperationsController,
         :approve_cleaner_application

    get "/admin/bookings/:id/payment-diagnostics",
        DirectOperationsController,
        :payment_diagnostics

    post "/admin/service-requests/:id/assign",
         DirectDispatchController,
         :assign_admin_service_request

    post "/admin/service-requests/:id/status",
         DirectDispatchController,
         :update_admin_service_request
  end
end
