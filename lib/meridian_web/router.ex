defmodule MeridianWeb.Router do
  use MeridianWeb, :router

  import MeridianWeb.AdminAuth, only: [require_admin_enabled: 2, require_admin: 2]
  import MeridianWeb.MeAuth, only: [require_me_enabled: 2, require_user: 2]

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

  @browser_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
        "img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
  }

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

    plug :put_secure_browser_headers, @browser_headers
  end

  # Where users manage their own things (see MeridianWeb.MeAuth). Its own session, separate
  # from the admin console's.
  pipeline :me do
    plug :require_me_enabled
    plug :accepts, ["html"]
    plug Plug.Session, MeridianWeb.MeAuth.session_options()
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MeridianWeb.Layouts, :me_root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @browser_headers
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

    get "/agents", AgentController, :index
    resources "/threads", ThreadController, except: [:new, :edit]
    post "/threads/:id/fork", ThreadController, :fork
    post "/threads/:id/truncate", ThreadController, :truncate
    post "/threads/:id/reply", ThreadController, :reply
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
    get "/extensions/:id/export", ExtensionController, :export

    live_session :admin, on_mount: [{MeridianWeb.AdminAuth, :require_admin}, MeridianWeb.Nav] do
      live "/users", UserLive.Index, :index
      live "/requests", AccessRequestLive.Index, :index
      live "/users/new", UserLive.Form, :new
      live "/users/:id", UserLive.Show, :show
      live "/users/:id/edit", UserLive.Form, :edit
      live "/users/:user_id/keys/new", ApiKeyLive.Form, :new
      live "/keys/:id/edit", ApiKeyLive.Form, :edit
      live "/users/:user_id/agents/new", AgentLive.Form, :new
      live "/agents/:id/edit", AgentLive.Form, :edit
      live "/runs", RunLive.Index, :index
      live "/runs/:id", RunLive.Show, :show
      live "/agents", AgentLive.Index, :index
      live "/extensions", ExtensionLive.Index, :index
      live "/extensions/new", ExtensionLive.Form, :new
      live "/extensions/:id", ExtensionLive.Form, :edit
      live "/skills", SkillLive.Index, :index
      live "/skills/new", SkillLive.Form, :new
      live "/skills/:id", SkillLive.Form, :edit
    end
  end

  scope "/me", MeridianWeb.Me do
    pipe_through :me

    get "/login", SessionController, :new
    post "/logout", SessionController, :delete
    get "/auth/oidc", SessionController, :oidc
    get "/auth/callback", SessionController, :callback
    get "/request", AccessRequestController, :new
    post "/request", AccessRequestController, :create
  end

  scope "/me", MeridianWeb.Me do
    pipe_through [:me, :require_user]

    get "/extensions/:id/export", ExtensionController, :export

    live_session :me, on_mount: [{MeridianWeb.MeAuth, :require_user}, MeridianWeb.Nav] do
      live "/", AgentLive.Index, :index
      live "/agents/new", AgentLive.Form, :new
      live "/agents/:id/edit", AgentLive.Form, :edit
      live "/extensions", ExtensionLive.Index, :index
      live "/extensions/new", ExtensionLive.Form, :new
      live "/extensions/:id", ExtensionLive.Form, :edit
      live "/skills", SkillLive.Index, :index
      live "/skills/new", SkillLive.Form, :new
      live "/skills/:id", SkillLive.Form, :edit
    end
  end
end
