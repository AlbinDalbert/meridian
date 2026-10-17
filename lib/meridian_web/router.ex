defmodule MeridianWeb.Router do
  use MeridianWeb, :router

  import MeridianWeb.AdminAuth, only: [require_admin_enabled: 2, require_admin: 2]

  # The native API. Authenticated like /v1; errors use the same shape.
  pipeline :api do
    plug :accepts, ["json"]
    plug MeridianWeb.Plugs.ApiKeyAuth, session: true
  end

  # Server-sent event streams. No `accepts`: clients send `Accept: text/event-stream`. Also
  # accepts a run's events token in the query string, for browsers' EventSource.
  pipeline :api_stream do
    plug MeridianWeb.Plugs.ApiKeyAuth, events_token: true, session: true
  end

  # The OpenAI-compatible surface. No `accepts` here: OpenAI clients send all sorts of Accept
  # headers (including text/event-stream for streaming).
  pipeline :openai do
    plug MeridianWeb.Plugs.ApiKeyAuth
  end

  # The admin console's cookie session. The APIs' own sign-in session is separate (see
  # MeridianWeb.UserAuth).
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

  # Signing users of browser apps in (see MeridianWeb.UserAuth). Unauthenticated: these start
  # and end sessions.
  scope "/api/auth", MeridianWeb.Api do
    get "/session", AuthController, :show
    get "/login", AuthController, :login
    get "/callback", AuthController, :callback
    post "/logout", AuthController, :logout
  end

  scope "/api", MeridianWeb.Api do
    pipe_through :api

    get "/personas", PersonaController, :index
    resources "/threads", ThreadController, except: [:new, :edit]
    get "/threads/:thread_id/messages", MessageController, :index
    post "/threads/:thread_id/messages", MessageController, :create
    get "/runs/:id", RunController, :show
    post "/runs/:id/cancel", RunController, :cancel
  end

  scope "/api", MeridianWeb.Api do
    pipe_through :api_stream

    get "/runs/:id/events", RunEventController, :index
  end

  scope "/admin", MeridianWeb.Admin do
    pipe_through :admin

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete
    get "/auth/oidc", OIDCController, :new
    get "/auth/callback", OIDCController, :callback
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
      live "/threads/:id", ThreadLive.Show, :show
      live "/runs", RunLive.Index, :index
      live "/runs/:id", RunLive.Show, :show
    end
  end
end
