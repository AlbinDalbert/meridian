defmodule MeridianWeb.Admin.OIDCHTML do
  use MeridianWeb, :html

  # Moves on with a same-site navigation (no script, the CSP forbids inline ones), so the
  # SameSite=Strict session cookie set by this response is sent. See MeridianWeb.Admin.OIDCController.
  def signed_in(assigns) do
    ~H"""
    <meta http-equiv="refresh" content={"0;url=#{~p"/admin/users"}"} />
    <div class="scrim">
      <.masthead sub="admin console" />
      <div class="dialog">
        <div class="bar">Signed in</div>
        <div class="content">
          <p>Taking you to the admin console.</p>
          <div class="actions">
            <a href={~p"/admin/users"} class="btn primary">Continue</a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
