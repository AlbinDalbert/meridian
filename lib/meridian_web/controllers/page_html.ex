defmodule MeridianWeb.PageHTML do
  use MeridianWeb, :html

  # A front-door page (public.css): the admin console's card in its green, the user's in amber.
  # Each links to its area, which sends people who aren't signed in to its sign-in page. Areas
  # that aren't set up are left out.
  def home(assigns) do
    ~H"""
    <div class="scrim">
      <.masthead sub="" />
      <div class="choices">
        <div :if={@admin} class="dialog theme-admin">
          <div class="bar">Operator</div>
          <div class="content">
            <p>Run the instance: users, runs, agents.</p>
            <div class="actions">
              <a href={~p"/admin"} class="btn primary">Admin sign-in</a>
            </div>
          </div>
        </div>
        <div :if={@me} class="dialog">
          <div class="bar">User</div>
          <div class="content">
            <p>Manage your agents.</p>
            <div class="actions">
              <a href={~p"/me"} class="btn primary">Sign in</a>
              <a href={~p"/me/request"} class="link">Request access</a>
            </div>
          </div>
        </div>
      </div>
      <a href={~p"/docs"} class="link">Docs</a>
    </div>
    """
  end
end
