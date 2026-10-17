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

  @doc "The admin page frame: sidebar, flash, content."
  attr :flash, :map, required: true
  attr :current_path, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="shell">
      <.sidebar
        home={~p"/admin/users"}
        area="admin"
        sections={admin_sections()}
        current_path={@current_path}
      >
        <:footer>
          <.form for={%{}} action={~p"/admin/logout"} method="post">
            <button type="submit" class="link">Log out</button>
          </.form>
        </:footer>
      </.sidebar>
      <main>
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc "The `/me` page frame. Without `current_user`, nobody is signed in."
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_path, :string, default: nil
  slot :inner_block, required: true

  def me(assigns) do
    ~H"""
    <div class="shell">
      <.sidebar
        home={~p"/me"}
        sections={if @current_user, do: me_sections(), else: []}
        current_path={@current_path}
      >
        <:footer :if={@current_user}>
          <span class="muted sidebar-user">{@current_user.email}</span>
          <.form for={%{}} action={~p"/me/logout"} method="post">
            <button type="submit" class="link">Log out</button>
          </.form>
        </:footer>
      </.sidebar>
      <main>
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  # The sidebar's groups. The admin console has its own (operating the instance) above the one
  # it shares with /me: the crew and what it can use. Pages differ between the two, but the
  # entries are the same. `match` lists path prefixes that also count as being on that page;
  # entries without `to` aren't built yet.
  defp admin_sections do
    [
      {"Operate",
       [
         %{label: "Users", to: ~p"/admin/users", match: ["/admin/users/", "/admin/keys/"]},
         %{label: "Requests", to: ~p"/admin/requests"},
         %{label: "Runs", to: ~p"/admin/runs", match: ["/admin/runs/"]}
       ]},
      {"Configure",
       configure_items(%{
         crew: {~p"/admin/crew", ["/admin/personas/"]},
         extensions: ~p"/admin/extensions"
       })}
    ]
  end

  defp me_sections do
    [
      {"Configure",
       configure_items(%{crew: {~p"/me", ["/me/personas/"]}, extensions: ~p"/me/extensions"})}
    ]
  end

  defp configure_items(%{crew: {crew, crew_match}, extensions: extensions}) do
    [
      %{label: "Crew", to: crew, match: crew_match},
      %{label: "Skills"},
      %{label: "MCPs"},
      %{label: "Extensions", to: extensions}
    ]
  end

  attr :home, :string, required: true
  attr :area, :string, default: nil
  attr :sections, :list, required: true
  attr :current_path, :string, default: nil
  slot :footer

  defp sidebar(assigns) do
    ~H"""
    <aside class="sidebar">
      <a href={@home} class="brand">
        <.mark size={22} /><span class="brand-word">MERIDIAN</span>
        <span :if={@area} class="brand-area">{@area}</span>
      </a>
      <nav>
        <div :for={{label, items} <- @sections} class="nav-section">
          <p class="nav-label">{label}</p>
          <%= for item <- items do %>
            <.link
              :if={item[:to]}
              navigate={item.to}
              class={["nav-item", active?(item, @current_path) && "active"]}
              aria-current={active?(item, @current_path) && "page"}
            >
              {item.label}
            </.link>
            <span :if={!item[:to]} class="nav-item disabled">
              {item.label} <span class="badge">soon</span>
            </span>
          <% end %>
        </div>
      </nav>
      <div :for={footer <- @footer} class="sidebar-footer">{render_slot(footer)}</div>
    </aside>
    """
  end

  defp active?(_item, nil), do: false

  defp active?(item, path),
    do: path == item.to or Enum.any?(Map.get(item, :match, []), &String.starts_with?(path, &1))
end
