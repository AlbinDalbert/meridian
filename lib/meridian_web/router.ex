defmodule MeridianWeb.Router do
  use MeridianWeb, :router

  import MeridianWeb.AdminAuth, only: [require_admin_enabled: 2, require_admin: 2]

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The OpenAI-compatible surface. No `accepts` here: OpenAI clients send all sorts of Accept
  # headers (including text/event-stream for streaming).
  pipeline :openai do
    plug MeridianWeb.Plugs.ApiKeyAuth
  end

  # Cookie sessions exist only in this pipeline; the APIs are API-key-only.
  pipeline :admin do
    plug :require_admin_enabled
    plug :accepts, ["html"]
    plug Plug.Session, MeridianWeb.AdminAuth.session_options()
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MeridianWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
          "img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    }
  end

  scope "/v1", MeridianWeb.V1 do
    pipe_through :openai

    get "/models", ModelController, :index
    post "/chat/completions", ChatCompletionController, :create
  end

  scope "/api", MeridianWeb do
    pipe_through :api
  end

  scope "/admin", MeridianWeb.Admin do
    pipe_through :admin

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
  end

  scope "/admin", MeridianWeb.Admin do
    pipe_through [:admin, :require_admin]

    get "/", RedirectController, :users

    live_session :admin, on_mount: {MeridianWeb.AdminAuth, :require_admin} do
      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Form, :new
      live "/users/:id", UserLive.Show, :show
      live "/users/:id/edit", UserLive.Form, :edit
      live "/users/:user_id/keys/new", ApiKeyLive.Form, :new
      live "/keys/:id/edit", ApiKeyLive.Form, :edit
      live "/users/:user_id/personas/new", PersonaLive.Form, :new
      live "/personas/:id/edit", PersonaLive.Form, :edit
    end
  end
end
