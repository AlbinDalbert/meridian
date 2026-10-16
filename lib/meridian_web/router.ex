defmodule MeridianWeb.Router do
  use MeridianWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MeridianWeb do
    pipe_through :api
  end
end
