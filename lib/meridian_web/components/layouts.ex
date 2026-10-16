defmodule MeridianWeb.Layouts do
  @moduledoc """
  Layouts for the admin console.
  """
  use MeridianWeb, :html

  @doc "The HTML document shell."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="robots" content="noindex" />
        <.live_title suffix=" · Meridian admin">{assigns[:page_title] || "Admin"}</.live_title>
        <link rel="stylesheet" href={~p"/assets/admin.css"} />
        <script defer src={~p"/assets/vendor/phoenix.min.js"}>
        </script>
        <script defer src={~p"/assets/vendor/phoenix_live_view.min.js"}>
        </script>
        <script defer src={~p"/assets/admin.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "The page frame: navigation, flash, content."
  attr :flash, :map, required: true
  attr :signed_in, :boolean, default: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <nav class="topbar">
      <a href={~p"/admin/users"} class="brand">Meridian</a>
      <.link :if={@signed_in} navigate={~p"/admin/users"}>Users</.link>
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
end
