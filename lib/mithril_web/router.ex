defmodule MithrilWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
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

  scope "/auth", MithrilWeb do
    pipe_through :api

    post "/login", AuthController, :login
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

    get "/placements", DirectController, :list_placements
    post "/placements", DirectController, :create_placement
    get "/placements/:id", DirectController, :show_placement

    get "/helpers", DirectController, :list_helpers
    post "/helpers", DirectController, :create_helper

    post "/matches/:id/hire", DirectController, :hire_match

    get "/admin/placements", DirectController, :list_admin_placements
    get "/admin/candidates", DirectController, :list_admin_candidates
    post "/admin/placements/:id/matches", DirectController, :match_admin_candidate
  end
end
