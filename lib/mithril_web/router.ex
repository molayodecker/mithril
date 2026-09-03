defmodule MithrilWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MithrilWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
