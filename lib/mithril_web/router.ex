defmodule MithrilWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :parity do
    plug MithrilWeb.Plugs.ParityAuth
  end

  scope "/", MithrilWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/internal/parity", MithrilWeb do
    pipe_through [:api, :parity]

    get "/bookings/:id", ParityBookingController, :show
  end
end
