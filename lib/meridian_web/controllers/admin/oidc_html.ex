defmodule MeridianWeb.Admin.OIDCHTML do
  use MeridianWeb, :html

  # Moves on with a same-site navigation (no script, the CSP forbids inline ones), so the
  # SameSite=Strict session cookie set by this response is sent. See MeridianWeb.Admin.OIDCController.
  def signed_in(assigns) do
    ~H"""
    <meta http-equiv="refresh" content={"0;url=#{~p"/admin/users"}"} />
    <Layouts.app flash={@flash} signed_in={false}>
      <div class="login">
        <p>Signed in. <a href={~p"/admin/users"}>Continue to the admin console</a>.</p>
      </div>
    </Layouts.app>
    """
  end
end
