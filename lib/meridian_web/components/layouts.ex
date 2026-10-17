defmodule MeridianWeb.Layouts do
  @moduledoc """
  Layouts for the admin console (`root/1`, `app/1`), the user area under `/me` (`me_root/1`,
  `me/1`), and the front-door pages: the request page and the admin login (`public_root/1`).
  """
  use MeridianWeb, :html

  @doc "The admin console's HTML document shell."
  def root(assigns) do
    assigns
    |> Map.merge(%{
      title: assigns[:page_title] || "Admin",
      title_suffix: " · Meridian admin",
      live_socket_path: "/admin/live",
      body_class: nil,
      icon: "/assets/favicon-admin.svg"
    })
    |> document()
  end

  @doc "The HTML document shell for `/me`."
  def me_root(assigns) do
    assigns
    |> Map.merge(%{
      title: assigns[:page_title] || "Me",
      title_suffix: " · Meridian",
      live_socket_path: "/me/live",
      body_class: "theme-me",
      icon: "/assets/favicon.svg"
    })
    |> document()
  end

  @doc """
  The HTML document shell for the front-door pages (the request page and the admin login): no
  LiveView, and their own stylesheet, in the look of xebec's login. Amber by default; with
  `theme: "admin"` assigned, in the admin console's green.
  """
  def public_root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <.live_title suffix={if assigns[:theme] == "admin", do: " · Meridian admin", else: " · Meridian"}>
          {assigns[:page_title] || "Meridian"}
        </.live_title>
        <link
          rel="icon"
          type="image/svg+xml"
          href={
            if assigns[:theme] == "admin",
              do: ~p"/assets/favicon-admin.svg",
              else: ~p"/assets/favicon.svg"
          }
        />
        <link rel="stylesheet" href={~p"/assets/public.css"} />
      </head>
      <body class={assigns[:theme] && "theme-#{assigns[:theme]}"}>
        {@inner_content}
      </body>
    </html>
    """
  end

  # Each area connects to its own LiveView socket (see priv/static/assets/live.js). The root
  # layout's assigns are a plain map, not change-tracked, hence `Map.merge/2` above.
  defp document(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="live-socket-path" content={@live_socket_path} />
        <meta name="robots" content="noindex" />
        <.live_title suffix={@title_suffix}>{@title}</.live_title>
        <link rel="icon" type="image/svg+xml" href={@icon} />
        <link rel="stylesheet" href={~p"/assets/admin.css"} />
        <script defer src={~p"/assets/vendor/phoenix.min.js"}>
        </script>
        <script defer src={~p"/assets/vendor/phoenix_live_view.min.js"}>
        </script>
        <script defer src={~p"/assets/live.js"}>
        </script>
      </head>
      <body class={@body_class}>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "The admin page frame: navigation, flash, content."
  attr :flash, :map, required: true
  attr :signed_in, :boolean, default: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <nav class="topbar">
      <a href={~p"/admin/users"} class="brand">
        <.mark size={22} /><span class="brand-word">MERIDIAN</span>
        <span class="brand-area">admin</span>
      </a>
      <.link :if={@signed_in} navigate={~p"/admin/users"}>Users</.link>
      <.link :if={@signed_in} navigate={~p"/admin/requests"}>Requests</.link>
      <.link :if={@signed_in} navigate={~p"/admin/runs"}>Runs</.link>
      <.form :if={@signed_in} for={%{}} action={~p"/admin/logout"} method="post" class="logout">
        <button type="submit" class="link">Log out</button>
      </.form>
    </nav>
    <main>
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </main>
    """
  end

  @doc "The `/me` page frame. Without `current_user`, nobody is signed in."
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  slot :inner_block, required: true

  def me(assigns) do
    ~H"""
    <nav class="topbar">
      <a href={~p"/me"} class="brand"><.mark size={22} /><span class="brand-word">MERIDIAN</span></a>
      <.link :if={@current_user} navigate={~p"/me"}>Crew</.link>
      <span :if={@current_user} class="muted topbar-user">{@current_user.email}</span>
      <.form
        :if={@current_user}
        for={%{}}
        action={~p"/me/logout"}
        method="post"
        class="logout"
      >
        <button type="submit" class="link">Log out</button>
      </.form>
    </nav>
    <main>
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </main>
    """
  end
end
