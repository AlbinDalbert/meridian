defmodule MeridianWeb.Me.SessionHTML do
  use MeridianWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.me flash={@flash}>
      <div class="login">
        <.header>
          Meridian
          <:subtitle>Sign in to manage your personas.</:subtitle>
        </.header>
        <%!-- A link, not a form: the CSP's form-action would block the redirect to the provider. --%>
        <section class="card">
          <a href={~p"/me/auth/oidc"} class="btn btn-primary login-oidc">Sign in</a>
        </section>
      </div>
    </Layouts.me>
    """
  end
end
