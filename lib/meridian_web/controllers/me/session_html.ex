defmodule MeridianWeb.Me.SessionHTML do
  use MeridianWeb, :html

  # A front-door page like the request page (public.css), in xebec's amber.
  def new(assigns) do
    ~H"""
    <div class="scrim">
        <.masthead sub="" />
      <div class="dialog">
        <div class="bar">Sign in</div>
        <div class="content">
          <p>Sign in to manage your crew.</p>
          <%!-- A link, not a form: the CSP's form-action would block the redirect to the provider. --%>
          <div class="actions">
            <a href={~p"/me/auth/oidc"} class="btn primary">Sign in</a>
            <a href={~p"/me/request"} class="link">No access yet? Request it</a>
          </div>
          <p :if={Phoenix.Flash.get(@flash, :error)} class="error">
            ▲ {Phoenix.Flash.get(@flash, :error)}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
